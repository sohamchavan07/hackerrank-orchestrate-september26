# frozen_string_literal: true

require 'csv'
require 'set'
require_relative 'dataset'
require_relative 'money'
require_relative 'unstructured_context'
require_relative 'financial_engine'
require_relative 'image_amount_extractor'
require_relative 'message_fact_extractor'
require_relative 'payment_planner'
require_relative 'decision_explanation'
require_relative 'output_validator'

# Pipeline — Stage 9: full dataset orchestration.
module Pipeline
  OUTPUT_COLUMNS = %w[
    request_id
    amount_safe_to_pay
    affordability_status
    recommended_payment_method
    payment_plan
    earliest_date_for_full_payment
    spending_changes_needed
    decision_explanation
  ].freeze

  RunStats = Struct.new(
    :requests_processed,
    :output_rows,
    :requests_requiring_llm,
    :deterministic_only_requests,
    :image_extractions,
    :message_extractions,
    :validation_failures,
    keyword_init: true
  )

  class Error < StandardError; end
  class ValidationError < Error; end
  class ProviderConfigError < Error; end

  def self.run(output_path: default_output_path, vision_provider: nil, message_provider: nil)
    data = load_dataset
    contexts = UnstructuredContext.build.contexts

    stats = RunStats.new(
      requests_processed: 0,
      output_rows: 0,
      requests_requiring_llm: 0,
      deterministic_only_requests: 0,
      image_extractions: 0,
      message_extractions: 0,
      validation_failures: 0
    )

    vision_provider, message_provider = resolve_providers(
      data, contexts, vision_provider, message_provider, stats
    )

    extraction_cache = build_image_cache(data, vision_provider, stats)
    message_cache = build_message_cache(data, contexts, message_provider, stats)

    rows = []
    validation_errors = []

    data[:requests].each do |request|
      stats.requests_processed += 1
      req_id = request['request_id']
      ctx = contexts[req_id]

      if ctx&.has_unstructured_context
        stats.requests_requiring_llm += 1
      else
        stats.deterministic_only_requests += 1
      end

      row = process_request(
        request, data, ctx, extraction_cache, message_cache
      )

      profile = data[:profile_map][request['user_id']]
      forecast = row.delete(:_forecast)
      errors = OutputValidator.validate(row, request, profile, forecast)

      if errors.any?
        stats.validation_failures += 1
        validation_errors << { request_id: req_id, errors: errors }
      else
        rows << row
      end
    end

    if validation_errors.any?
      validation_errors.each do |entry|
        warn "VALIDATION FAILED #{entry[:request_id]}: #{entry[:errors].join('; ')}"
      end
      raise ValidationError, "#{validation_errors.size} row(s) failed OutputValidator"
    end

    verify_counts!(data[:requests], rows)
    write_output!(output_path, rows)

    stats.output_rows = rows.size
    stats
  end

  # Process a single request and return an output Hash (includes :_forecast for validation).
  def self.process_request(request, data, ctx, extraction_cache, message_cache)
    profile = data[:profile_map][request['user_id']]
    raise Error, "No profile for user #{request['user_id']}" unless profile

    message_facts = extract_message_facts(ctx, data, message_cache)

    forecast = FinancialEngine.evaluate_request(
      request, profile, data[:events],
      extraction_cache: extraction_cache,
      message_facts: message_facts
    )

    payment_options = data[:pay_opts_by_req][request['request_id']] || []
    plan_result = PaymentPlanner.select_plan(
      request, profile, forecast, payment_options,
      events: data[:events],
      extraction_cache: extraction_cache,
      message_facts: message_facts
    )

    explanation = DecisionExplanation.generate(request, profile, forecast, plan_result)

    {
      'request_id' => request['request_id'],
      'amount_safe_to_pay' => plan_result[:amount_safe_to_pay],
      'affordability_status' => plan_result[:affordability_status],
      'recommended_payment_method' => plan_result[:recommended_payment_method],
      'payment_plan' => plan_result[:payment_plan],
      'earliest_date_for_full_payment' => format_earliest_date(plan_result),
      'spending_changes_needed' => plan_result[:spending_changes_needed],
      'decision_explanation' => explanation,
      :_forecast => forecast
    }
  end

  def self.load_dataset
    requests = Dataset.load(:requests)
    profiles = Dataset.load(:financial_profiles)
    events = Dataset.load(:financial_events)
    images = Dataset.load(:images)
    messages = Dataset.load(:messages)
    pay_opts = Dataset.load(:request_payment_options)

    {
      requests: requests,
      events: events,
      images: images,
      messages: messages,
      profile_map: profiles.each_with_object({}) { |p, h| h[p['user_id']] = p },
      pay_opts_by_req: pay_opts.group_by { |o| o['request_id'] },
      messages_by_id: messages.each_with_object({}) { |m, h| h[m['message_id']] = m }
    }
  end

  def self.default_output_path
    File.join(Dataset::ROOT, 'output.csv')
  end

  def self.resolve_providers(data, contexts, vision_provider, message_provider, stats)
    needs_images = image_events_needed(data, contexts).any?
    needs_messages = contexts.values.any? { |c| c.message_ids.any? }

    vision_name = (ENV['VISION_PROVIDER'] || 'mock').downcase
    message_name = (ENV['MESSAGE_PROVIDER'] || ENV['LLM_PROVIDER'] || 'mock').downcase

    if needs_images && vision_name != 'mock'
      begin
        vision_provider ||= ImageAmountExtractor.default_provider
      rescue ArgumentError => e
        raise ProviderConfigError, "Vision provider misconfigured: #{e.message}"
      end
    else
      vision_provider ||= ImageAmountExtractor::MockVisionProvider.new
    end

    if needs_messages && message_name != 'mock'
      begin
        message_provider ||= MessageFactExtractor.default_provider
      rescue ArgumentError => e
        raise ProviderConfigError, "Message provider misconfigured: #{e.message}"
      end
    else
      message_provider ||= MessageFactExtractor::MockMessageProvider.new
    end

    [vision_provider, message_provider]
  end

  def self.image_events_needed(data, contexts)
    user_ids = data[:requests].map { |r| r['user_id'] }.uniq
    image_event_ids = contexts.values.flat_map(&:image_ids).to_set

    data[:events].select do |e|
      e['amount'].nil? &&
        user_ids.include?(e['user_id']) &&
        image_linked?(e, data[:images], image_event_ids)
    end
  end

  def self.image_linked?(event, images, _image_event_ids)
    images.any? { |img| img['related_event_id'] == event['event_id'] }
  end

  def self.build_image_cache(data, vision_provider, stats)
    user_ids = data[:requests].map { |r| r['user_id'] }.uniq
    relevant_events = data[:events].select do |e|
      e['amount'].nil? && user_ids.include?(e['user_id'])
    end

    stats.image_extractions = relevant_events.size

    return {} if relevant_events.empty?

    ImageAmountExtractor.build_cache(relevant_events, data[:images], provider: vision_provider)
  end

  def self.build_message_cache(data, contexts, message_provider, stats)
    message_ids = contexts.values.flat_map(&:message_ids).uniq
    stats.message_extractions = message_ids.size

    return {} if message_ids.empty?

    cache = {}
    known_event_ids = data[:events].map { |e| e['event_id'] }.compact.uniq

    message_ids.each do |mid|
      msg = data[:messages_by_id][mid]
      next unless msg

      cache[mid] = message_provider.extract(msg, known_event_ids)
    end

    cache
  end

  def self.extract_message_facts(ctx, data, message_cache)
    return [] if ctx.nil? || ctx.message_ids.empty?

    all_facts = []
    ctx.message_ids.each do |mid|
      result = message_cache[mid]
      next unless result&.success

      all_facts.concat(result.facts)
    end

    MessageFactExtractor.resolve_conflicts(all_facts, data[:messages_by_id])
  end

  def self.format_earliest_date(plan_result)
    method = plan_result[:recommended_payment_method]
    status = plan_result[:affordability_status]

    return '' if method == 'not_recommended' || status == 'not_affordable'

    earliest = plan_result[:earliest_date_for_full_payment]
    earliest ? earliest.to_s : ''
  end

  def self.format_amount_for_csv(bd)
    if bd == bd.to_i
      bd.to_i.to_s
    else
      s = bd.to_s('F')
      s.sub(/\.?0+$/, '')
    end
  end

  def self.row_for_csv(row)
    row.except(:_forecast).transform_values do |v|
      case v
      when BigDecimal then format_amount_for_csv(v)
      else v.to_s
      end
    end
  end

  def self.write_output!(output_path, rows)
    csv_rows = rows.map { |row| row_for_csv(row) }

    CSV.open(output_path, 'w', write_headers: true, headers: OUTPUT_COLUMNS) do |csv|
      csv_rows.each { |r| csv << OUTPUT_COLUMNS.map { |col| r[col] } }
    end
  end

  def self.verify_counts!(requests, rows)
    input_ids = requests.map { |r| r['request_id'] }
    output_ids = rows.map { |r| r['request_id'] }

    raise Error, "row count mismatch: #{input_ids.size} requests, #{output_ids.size} rows" if input_ids.size != output_ids.size

    if output_ids.uniq.size != output_ids.size
      dupes = output_ids.group_by(&:itself).select { |_, v| v.size > 1 }.keys
      raise Error, "duplicate output request_ids: #{dupes.join(', ')}"
    end

    missing = input_ids - output_ids
    extra = output_ids - input_ids
    raise Error, "missing request_ids in output: #{missing.join(', ')}" if missing.any?
    raise Error, "extra request_ids in output: #{extra.join(', ')}" if extra.any?
  end
end
