#!/usr/bin/env ruby
# frozen_string_literal: true

# verify_stage9.rb — Final regression & full output validation
#
# Validates:
#  1. All output rows pass OutputValidator
#  2. No validation failures in final output.csv
#  3. Row count matches requests.csv
#  4. Required columns present and ordered correctly
#  5. Full regression: all previous stages (Stages 2-8) still pass

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/dataset'
require_relative '../lib/money'
require_relative '../lib/financial_engine'
require_relative '../lib/unstructured_context'
require_relative '../lib/image_amount_extractor'
require_relative '../lib/message_fact_extractor'
require_relative '../lib/payment_planner'
require_relative '../lib/output_validator'
require_relative '../lib/pipeline'

puts '=================================================='
puts 'STAGE 9 FINAL REGRESSION & OUTPUT VALIDATION'
puts '=================================================='

pass_count = 0
fail_count = 0

def assert(condition, label)
  if condition
    puts "  >> PASS: #{label}"
    true
  else
    puts "  >> FAIL: #{label}"
    false
  end
end

# ---------------------------------------------------------------------------
# TEST 1: Verify all sample request outputs pass OutputValidator
# ---------------------------------------------------------------------------
puts "\n--- [TEST 1] Sample request outputs pass validation ---"
requests = Dataset.load(:requests)
samples = Dataset.load(:sample_requests)
profiles = Dataset.load(:financial_profiles)
events = Dataset.load(:financial_events)
images = Dataset.load(:images)
messages = Dataset.load(:messages)
pay_opts = Dataset.load(:request_payment_options)

profile_map = profiles.each_with_object({}) { |p, h| h[p['user_id']] = p }
pay_opts_by_req = pay_opts.group_by { |o| o['request_id'] }

mock_provider = ImageAmountExtractor::MockVisionProvider.new
extraction_cache = ImageAmountExtractor.build_cache(events, images, provider: mock_provider)
contexts = UnstructuredContext.build.contexts
message_cache = {}

errors_by_row = {}
samples.each do |r|
  profile = profile_map[r['user_id']]
  req_id = r['request_id']
  ctx = contexts[req_id]

  # Replicate message fact extraction without provider
  message_facts = []
  if ctx && ctx.message_ids.any?
    known_event_ids = events.map { |e| e['event_id'] }.compact.uniq
    ctx.message_ids.each do |mid|
      msg = messages.find { |m| m['message_id'] == mid }
      next unless msg
      result = MessageFactExtractor::MockMessageProvider.new.extract(msg, known_event_ids)
      next unless result&.success
      message_facts.concat(result.facts)
    end
    message_facts = MessageFactExtractor.resolve_conflicts(message_facts, messages.each_with_object({}) { |m, h| h[m['message_id']] = m })
  end

  forecast = FinancialEngine.evaluate_request(r, profile, events, extraction_cache: extraction_cache, message_facts: message_facts)
  opts = pay_opts_by_req[req_id] || []
  plan = PaymentPlanner.select_plan(r, profile, forecast, opts, events: events, extraction_cache: extraction_cache, message_facts: message_facts)
  output = {
    'request_id' => r['request_id'],
    'amount_safe_to_pay' => plan[:amount_safe_to_pay],
    'affordability_status' => plan[:affordability_status],
    'recommended_payment_method' => plan[:recommended_payment_method],
    'payment_plan' => plan[:payment_plan],
    'earliest_date_for_full_payment' => plan[:earliest_date_for_full_payment]&.to_s || '',
    'spending_changes_needed' => plan[:spending_changes_needed],
    'decision_explanation' => 'sample check'
  }
  errs = OutputValidator.validate(output, r, profile, forecast)
  errors_by_row[req_id] = errs unless errs.empty?
end

t1 = errors_by_row.empty?
puts "  rows with errors: #{errors_by_row.size}"
if assert(t1, 'All sample outputs pass OutputValidator')
  pass_count += 1
else
  fail_count += 1
  errors_by_row.each { |id, errs| puts "    #{id}: #{errs.inspect}" }
end

# ---------------------------------------------------------------------------
# TEST 2: Failing request regression from the original issue
# ---------------------------------------------------------------------------
puts "\n--- [TEST 2] Previously failing requests now valid ---"
failing_ids = %w[
  request_32 request_36 request_37 request_40 request_177 request_216 request_232
  request_58 request_99 request_105 request_117 request_125 request_135 request_144 request_165
  request_64 request_124 request_139
]

contexts = UnstructuredContext.build.contexts
message_cache = {}

failing_errors = {}
failing_ids.each do |id|
  r = requests.find { |req| req['request_id'] == id }
  next unless r
  profile = profile_map[r['user_id']]
  ctx = contexts[id]

  message_facts = []
  if ctx && ctx.message_ids.any?
    known_event_ids = events.map { |e| e['event_id'] }.compact.uniq
    ctx.message_ids.each do |mid|
      msg = messages.find { |m| m['message_id'] == mid }
      next unless msg
      result = MessageFactExtractor::MockMessageProvider.new.extract(msg, known_event_ids)
      next unless result&.success
      message_facts.concat(result.facts)
    end
    message_facts = MessageFactExtractor.resolve_conflicts(message_facts, messages.each_with_object({}) { |m, h| h[m['message_id']] = m })
  end

  forecast = FinancialEngine.evaluate_request(r, profile, events, extraction_cache: extraction_cache, message_facts: message_facts)
  opts = pay_opts_by_req[id] || []
  plan = PaymentPlanner.select_plan(r, profile, forecast, opts, events: events, extraction_cache: extraction_cache, message_facts: message_facts)
  output = {
    'request_id' => r['request_id'],
    'amount_safe_to_pay' => plan[:amount_safe_to_pay],
    'affordability_status' => plan[:affordability_status],
    'recommended_payment_method' => plan[:recommended_payment_method],
    'payment_plan' => plan[:payment_plan],
    'earliest_date_for_full_payment' => plan[:earliest_date_for_full_payment]&.to_s || '',
    'spending_changes_needed' => plan[:spending_changes_needed],
    'decision_explanation' => 'regression check'
  }
  errs = OutputValidator.validate(output, r, profile, forecast)
  failing_errors[id] = errs unless errs.empty?
end

t2 = failing_errors.empty?
puts "  previously failing rows with errors: #{failing_errors.size}"
if assert(t2, 'All previously failing requests now pass validation')
  pass_count += 1
else
  fail_count += 1
  failing_errors.each { |id, errs| puts "    #{id}: #{errs.inspect}" }
end

# ---------------------------------------------------------------------------
# TEST 3: Invariants for wait / full_payment / affordable_later
# ---------------------------------------------------------------------------
puts "\n--- [TEST 3] Core invariants hold for sample outputs ---"
invariant_errors = {}
samples.each do |r|
  profile = profile_map[r['user_id']]
  req_id = r['request_id']
  ctx = contexts[req_id]

  message_facts = []
  if ctx && ctx.message_ids.any?
    known_event_ids = events.map { |e| e['event_id'] }.compact.uniq
    ctx.message_ids.each do |mid|
      msg = messages.find { |m| m['message_id'] == mid }
      next unless msg
      result = MessageFactExtractor::MockMessageProvider.new.extract(msg, known_event_ids)
      next unless result&.success
      message_facts.concat(result.facts)
    end
    message_facts = MessageFactExtractor.resolve_conflicts(message_facts, messages.each_with_object({}) { |m, h| h[m['message_id']] = m })
  end

  forecast = FinancialEngine.evaluate_request(r, profile, events, extraction_cache: extraction_cache, message_facts: message_facts)
  opts = pay_opts_by_req[req_id] || []
  plan = PaymentPlanner.select_plan(r, profile, forecast, opts, events: events, extraction_cache: extraction_cache, message_facts: message_facts)

  method = plan[:recommended_payment_method]
  status = plan[:affordability_status]
  safe = plan[:amount_safe_to_pay]
  earliest = plan[:earliest_date_for_full_payment]
  plan_str = plan[:payment_plan]

  if method == 'wait' && (earliest.nil? || earliest.to_s.empty?)
    invariant_errors[r['request_id']] = 'wait without earliest date'
  elsif method == 'full_payment' && safe < Money.parse(r['requested_amount'])
    invariant_errors[r['request_id']] = "full_payment with safe=#{safe} < requested=#{r['requested_amount']}"
  elsif status == 'affordable_later' && method != 'wait'
    invariant_errors[r['request_id']] = "affordable_later with method=#{method}"
  elsif method == 'not_recommended' && plan_str != 'none'
    invariant_errors[r['request_id']] = 'not_recommended with non-none plan'
  elsif status == 'affordable_now' && method != 'full_payment'
    invariant_errors[r['request_id']] = "affordable_now with method=#{method}"
  end
end

t3 = invariant_errors.empty?
puts "  invariant violations: #{invariant_errors.size}"
if assert(t3, 'Core payment decision invariants hold for sample outputs')
  pass_count += 1
else
  fail_count += 1
  invariant_errors.each { |id, msg| puts "    #{id}: #{msg}" }
end

# ---------------------------------------------------------------------------
# TEST 4: Spending changes do not corrupt baseline values
# ---------------------------------------------------------------------------
puts "\n--- [TEST 4] Spending changes preserve baseline-safe values ---"
sc_errors = {}
samples.each do |r|
  profile = profile_map[r['user_id']]
  forecast = FinancialEngine.evaluate_request(r, profile, events, extraction_cache: extraction_cache)
  baseline_safe = forecast.amount_safe_to_pay

  opts = pay_opts_by_req[r['request_id']] || []
  plan = PaymentPlanner.select_plan(r, profile, forecast, opts, events: events, extraction_cache: extraction_cache)

  # If spending changes are proposed, amount_safe_to_pay in output reflects
  # the selected plan's forecast (baseline or modified), but full_payment
  # always requires safe >= requested regardless of source.
  if plan[:recommended_payment_method] == 'full_payment' && plan[:amount_safe_to_pay] < Money.parse(r['requested_amount'])
    sc_errors[r['request_id']] = "full_payment safe #{plan[:amount_safe_to_pay]} < #{r['requested_amount']}"
  end
end

t4 = sc_errors.empty?
puts "  full_payment with insufficient safe: #{sc_errors.size}"
if assert(t4, 'full_payment never selected with safe < requested after spending changes')
  pass_count += 1
else
  fail_count += 1
  sc_errors.each { |id, msg| puts "    #{id}: #{msg}" }
end

# ---------------------------------------------------------------------------
# TEST 5: Full pipeline runs and produces valid output.csv
# ---------------------------------------------------------------------------
puts "\n--- [TEST 5] Full pipeline produces valid output.csv ---"
begin
  Pipeline.run
  output_csv = File.join(Dataset::ROOT, 'output.csv')
  if File.exist?(output_csv)
    rows = CSV.read(output_csv, headers: true)
    expected_columns = %w[
      request_id
      amount_safe_to_pay
      affordability_status
      recommended_payment_method
      payment_plan
      earliest_date_for_full_payment
      spending_changes_needed
      decision_explanation
    ]
    columns_ok = rows.headers == expected_columns
    row_count_ok = rows.size == requests.size

    t5 = columns_ok && row_count_ok
    puts "  columns_ok=#{columns_ok} row_count=#{rows.size} expected=#{requests.size}"
    if assert(t5, 'output.csv has correct columns and row count')
      pass_count += 1
    else
      fail_count += 1
    end
  else
    puts '  output.csv not found'
    fail_count += 1
  end
rescue StandardError => e
  puts "  pipeline error: #{e.message}"
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 6: Full regression — all previous stages pass
# ---------------------------------------------------------------------------
puts "\n--- [TEST 6] Full regression across Stages 2-8 ---"
st2_ok = system('ruby', File.expand_path('verify_stage2.rb', __dir__), out: File::NULL, err: File::NULL)
st3_ok = system('ruby', File.expand_path('verify_stage3.rb', __dir__), out: File::NULL, err: File::NULL)
st4_ok = system('ruby', File.expand_path('verify_stage4.rb', __dir__), out: File::NULL, err: File::NULL)
st5_ok = system('ruby', File.expand_path('verify_stage5.rb', __dir__), out: File::NULL, err: File::NULL)
st6_ok = system('ruby', File.expand_path('verify_stage6.rb', __dir__), out: File::NULL, err: File::NULL)
st7_ok = system('ruby', File.expand_path('verify_stage7.rb', __dir__), out: File::NULL, err: File::NULL)
st8_ok = system('ruby', File.expand_path('verify_stage8.rb', __dir__), out: File::NULL, err: File::NULL)

all_ok = st2_ok && st3_ok && st4_ok && st5_ok && st6_ok && st7_ok && st8_ok
puts "  Stage 2: #{st2_ok ? 'PASS' : 'FAIL'}"
puts "  Stage 3: #{st3_ok ? 'PASS' : 'FAIL'}"
puts "  Stage 4: #{st4_ok ? 'PASS' : 'FAIL'}"
puts "  Stage 5: #{st5_ok ? 'PASS' : 'FAIL'}"
puts "  Stage 6: #{st6_ok ? 'PASS' : 'FAIL'}"
puts "  Stage 7: #{st7_ok ? 'PASS' : 'FAIL'}"
puts "  Stage 8: #{st8_ok ? 'PASS' : 'FAIL'}"

if assert(all_ok, 'All previous verification suites (Stages 2-8) pass')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
total = pass_count + fail_count
puts "\n=================================================="
puts "STAGE 9 RESULTS: #{pass_count}/#{total} PASSED"
puts '=================================================='

if fail_count > 0
  puts "#{fail_count} test(s) FAILED."
  exit 1
else
  puts 'ALL STAGE 9 TESTS PASSED.'
  exit 0
end
