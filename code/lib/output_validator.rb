# frozen_string_literal: true

require 'date'
require 'bigdecimal'
require_relative 'money'

# OutputValidator — Stage 8: Final deterministic hard validator.
#
# This is the safety boundary before any row is written to output.csv.
# It enforces the HackerRank specification contract on every output hash
# returned by PaymentPlanner.select_plan + FinancialEngine.evaluate_request.
#
# NO LLM is used here. Every check is deterministic.
# Invalid rows produce structured errors; nothing is silently invented.
#
# Usage:
#   errors = OutputValidator.validate(output, request, profile, forecast)
#   # errors is an Array<String>; empty means valid.
#
# Parameters:
#   output   — Hash (merged output: PaymentPlanner result + forecast fields)
#   request  — Hash (one row from requests.csv)
#   profile  — Hash (one row from financial_profiles.csv)
#   forecast — FinancialEngine::ForecastResult
module OutputValidator
  VALID_AFFORDABILITY = %w[
    affordable_now
    affordable_with_plan
    affordable_later
    not_affordable
  ].freeze

  VALID_METHODS = %w[
    full_payment
    partial_payment
    installments
    wait
    not_recommended
  ].freeze

  REQUIRED_FIELDS = %w[
    request_id
    amount_safe_to_pay
    affordability_status
    recommended_payment_method
    payment_plan
    earliest_date_for_full_payment
    spending_changes_needed
    decision_explanation
  ].freeze

  # Validate a single output row.
  # Returns Array<String> of error messages; empty = valid.
  def self.validate(output, request, profile, forecast)
    errors = []

    # 1. Required fields present and non-nil
    errors.concat(check_required_fields(output))
    return errors if errors.any? # further checks require these fields

    # 2. request_id matches
    if output['request_id'].to_s.strip != request['request_id'].to_s.strip
      errors << "request_id mismatch: output=#{output['request_id']} request=#{request['request_id']}"
    end

    # 3. affordability_status is a valid enum
    unless VALID_AFFORDABILITY.include?(output['affordability_status'])
      errors << "Invalid affordability_status: #{output['affordability_status'].inspect}"
    end

    # 4. recommended_payment_method is a valid enum
    unless VALID_METHODS.include?(output['recommended_payment_method'])
      errors << "Invalid recommended_payment_method: #{output['recommended_payment_method'].inspect}"
    end

    # 5. amount_safe_to_pay is BigDecimal (never Float), >= 0, <= requested_amount
    errors.concat(check_amount_safe(output, request))

    # 6. payment_plan format validity
    errors.concat(check_payment_plan(output, request, forecast))

    # 7. earliest_date_for_full_payment constraints
    errors.concat(check_earliest_date(output, request))

    # 8. spending_changes_needed format
    errors.concat(check_spending_changes(output, forecast))

    # 9. Cross-field logical consistency checks
    errors.concat(check_cross_field_consistency(output, request, forecast))

    # 10. decision_explanation must be non-empty
    if output['decision_explanation'].to_s.strip.empty?
      errors << 'decision_explanation must be non-empty'
    end

    errors
  end

  # -------------------------------------------------------------------------
  private_class_method def self.check_required_fields(output)
    errors = []
    REQUIRED_FIELDS.each do |field|
      if !output.key?(field) || output[field].nil?
        errors << "Missing required field: #{field}"
      end
    end
    errors
  end

  private_class_method def self.check_amount_safe(output, request)
    errors = []
    raw = output['amount_safe_to_pay']

    # Must be BigDecimal — Float is never allowed in financial calculations
    unless raw.is_a?(BigDecimal)
      errors << "amount_safe_to_pay must be BigDecimal, got #{raw.class}: #{raw.inspect}"
      return errors
    end

    if raw < Money::ZERO
      errors << "amount_safe_to_pay must be >= 0, got #{raw}"
    end

    req_amt = begin
      Money.parse(request['requested_amount'])
    rescue StandardError
      nil
    end

    if req_amt && raw > req_amt
      errors << "amount_safe_to_pay (#{raw}) must be <= requested_amount (#{req_amt})"
    end

    errors
  end

  private_class_method def self.check_payment_plan(output, request, forecast)
    errors = []
    plan   = output['payment_plan'].to_s.strip
    method = output['recommended_payment_method'].to_s.strip

    if plan == 'none'
      # none is acceptable for not_recommended; error if a real method was chosen that needs a plan
      if %w[full_payment installments partial_payment wait].include?(method)
        errors << "payment_plan is 'none' but recommended_payment_method is #{method}"
      end
      return errors
    end

    # Parse each entry: YYYY-MM-DD:amount
    entries = plan.split('|')
    if entries.empty?
      errors << "payment_plan must be 'none' or have at least one YYYY-MM-DD:amount entry"
      return errors
    end

    dates   = []
    amounts = []
    entries.each_with_index do |entry, idx|
      parts = entry.split(':', 2)
      if parts.size != 2
        errors << "payment_plan entry #{idx + 1} malformed (expected YYYY-MM-DD:amount): #{entry.inspect}"
        next
      end

      date_str, amt_str = parts
      begin
        d = Date.parse(date_str)
        dates << d
      rescue ArgumentError
        errors << "payment_plan entry #{idx + 1} has invalid date: #{date_str.inspect}"
      end

      begin
        amt = BigDecimal(amt_str)
        if amt <= Money::ZERO
          errors << "payment_plan entry #{idx + 1} amount must be positive: #{amt_str.inspect}"
        end
        amounts << amt
      rescue ArgumentError
        errors << "payment_plan entry #{idx + 1} has invalid amount: #{amt_str.inspect}"
      end
    end

    return errors if errors.any?

    # Dates must be in chronological (non-decreasing) order
    dates.each_cons(2) do |a, b|
      if a > b
        errors << "payment_plan dates must be chronological: #{a} appears before #{b}"
      end
    end

    # partial_payment: exactly 2 payments; amounts must sum to requested_amount
    if method == 'partial_payment'
      if entries.size != 2
        errors << "partial_payment payment_plan must have exactly 2 entries, got #{entries.size}"
      elsif !amounts.empty?
        total   = amounts.reduce(Money::ZERO, :+)
        req_amt = Money.parse(request['requested_amount'])
        unless total == req_amt
          errors << "partial_payment amounts must sum to requested_amount (#{req_amt}), got #{total}"
        end

        # First payment must be on or before request_date
        req_date = Date.parse(request['request_date'])
        if dates[0] > req_date
          errors << "partial_payment first payment date (#{dates[0]}) must be <= request_date (#{req_date})"
        end
      end
    end

    errors
  end

  private_class_method def self.check_earliest_date(output, request)
    errors = []
    earliest_str = output['earliest_date_for_full_payment'].to_s.strip

    # Validate date format when non-empty
    unless earliest_str.empty?
      begin
        earliest = Date.parse(earliest_str)

        # For affordable_now: earliest must equal request_date
        if output['affordability_status'] == 'affordable_now'
          req_date = Date.parse(request['request_date'])
          unless earliest == req_date
            errors << "earliest_date_for_full_payment must equal request_date (#{req_date}) " \
                      "for affordable_now, got #{earliest}"
          end
        end
      rescue ArgumentError
        errors << "earliest_date_for_full_payment is not a valid date: #{earliest_str.inspect}"
      end
    end

    errors
  end

  private_class_method def self.check_spending_changes(output, forecast)
    errors = []
    sc = output['spending_changes_needed'].to_s.strip
    return errors if sc == 'none' || sc.empty?

    # Parse each action: stop:event_id or reduce_to:event_id:amount
    actions = sc.split('|')
    if actions.size > 3
      errors << "spending_changes_needed must have at most 3 actions, got #{actions.size}"
    end

    seen_event_ids = {}

    actions.each_with_index do |action, idx|
      parts = action.split(':')
      verb  = parts[0]

      if verb == 'stop'
        if parts.size != 2
          errors << "spending_changes_needed action #{idx + 1} malformed stop: #{action.inspect}"
          next
        end
        event_id = parts[1]
        if seen_event_ids.key?(event_id)
          errors << "spending_changes_needed: event_id #{event_id.inspect} appears more than once (mutual exclusivity)"
        end
        seen_event_ids[event_id] = :stop

        unless event_id.to_s.start_with?('event_')
          errors << "spending_changes_needed stop action has suspicious event_id format: #{event_id.inspect}"
        end

      elsif verb == 'reduce_to'
        if parts.size != 3
          errors << "spending_changes_needed action #{idx + 1} malformed reduce_to: #{action.inspect}"
          next
        end
        event_id = parts[1]
        amt_str  = parts[2]

        if seen_event_ids.key?(event_id)
          errors << "spending_changes_needed: event_id #{event_id.inspect} appears more than once (mutual exclusivity)"
        end
        seen_event_ids[event_id] = :reduce

        unless event_id.to_s.start_with?('event_')
          errors << "spending_changes_needed reduce_to has suspicious event_id format: #{event_id.inspect}"
        end

        begin
          new_amt = BigDecimal(amt_str)
          if new_amt <= Money::ZERO
            errors << "spending_changes_needed reduce_to amount must be positive: #{amt_str.inspect}"
          end
        rescue ArgumentError
          errors << "spending_changes_needed reduce_to has invalid amount: #{amt_str.inspect}"
        end

      else
        errors << "spending_changes_needed action #{idx + 1} has unknown verb: #{action.inspect}"
      end
    end

    errors
  end

  private_class_method def self.check_cross_field_consistency(output, request, forecast)
    errors = []
    method = output['recommended_payment_method'].to_s.strip
    status = output['affordability_status'].to_s.strip
    plan   = output['payment_plan'].to_s.strip
    sc     = output['spending_changes_needed'].to_s.strip

    # affordable_now → must be full_payment, no spending changes
    if status == 'affordable_now'
      unless method == 'full_payment'
        errors << "affordable_now requires recommended_payment_method=full_payment, got #{method.inspect}"
      end
      if sc != 'none' && !sc.empty?
        errors << "affordable_now must have spending_changes_needed=none, got #{sc.inspect}"
      end
    end

    # affordable_later → must be wait
    if status == 'affordable_later'
      unless method == 'wait'
        errors << "affordable_later requires recommended_payment_method=wait, got #{method.inspect}"
      end
    end

    # not_recommended → payment_plan must be 'none'
    if method == 'not_recommended' && plan != 'none'
      errors << "not_recommended must have payment_plan=none, got #{plan.inspect}"
    end

    # affordable_with_plan → method must be a real payment method
    if status == 'affordable_with_plan'
      unless %w[full_payment installments partial_payment wait].include?(method)
        errors << "affordable_with_plan requires a valid payment method, got #{method.inspect}"
      end
    end

    # wait → earliest_date_for_full_payment must be set and strictly > request_date
    if method == 'wait'
      earliest_str = output['earliest_date_for_full_payment'].to_s.strip
      if earliest_str.empty?
        errors << 'wait method requires earliest_date_for_full_payment to be set'
      else
        begin
          earliest = Date.parse(earliest_str)
          req_date = Date.parse(request['request_date'])
          if earliest <= req_date
            errors << "wait method requires earliest_date_for_full_payment (#{earliest}) > request_date (#{req_date})"
          end
        rescue ArgumentError
          # date parse error already caught in check_earliest_date
        end
      end
    end

    # full_payment → amount_safe_to_pay must equal requested_amount
    if method == 'full_payment' && output['amount_safe_to_pay'].is_a?(BigDecimal)
      req_amt  = Money.parse(request['requested_amount'])
      safe_amt = output['amount_safe_to_pay']
      if safe_amt < req_amt
        errors << "full_payment requires amount_safe_to_pay (#{safe_amt}) >= requested_amount (#{req_amt})"
      end
    end

    errors
  end
end
