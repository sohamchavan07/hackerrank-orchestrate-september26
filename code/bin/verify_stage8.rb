#!/usr/bin/env ruby
# frozen_string_literal: true

# verify_stage8.rb — Stage 8: Output Validator Verification
#
# Tests:
#  1.  Valid affordable_now / full_payment row passes with no errors
#  2.  Missing required field is detected
#  3.  Invalid affordability_status enum is rejected
#  4.  Invalid recommended_payment_method enum is rejected
#  5.  Float amount_safe_to_pay is rejected (must be BigDecimal)
#  6.  amount_safe_to_pay > requested_amount is rejected
#  7.  amount_safe_to_pay < 0 is rejected
#  8.  Malformed payment_plan entry (no colon) is rejected
#  9.  Non-chronological payment_plan dates are rejected
# 10.  partial_payment amounts not summing to requested_amount is rejected
# 11.  partial_payment with wrong number of entries is rejected
# 12.  spending_changes_needed with 4 actions is rejected
# 13.  spending_changes_needed with duplicate event_id is rejected
# 14.  spending_changes_needed reduce_to with negative amount is rejected
# 15.  affordable_now + spending changes is rejected
# 16.  affordable_now without full_payment method is rejected
# 17.  affordable_later without wait method is rejected
# 18.  not_recommended with non-none payment_plan is rejected
# 19.  wait without earliest_date_for_full_payment is rejected
# 20.  wait where earliest <= request_date is rejected
# 21.  full_payment where amount_safe_to_pay < requested_amount is rejected
# 22.  payment_plan=none for full_payment method is rejected
# 23.  Real dataset sample request_01 passes validation
# 24.  Real dataset sample request_22 passes validation
# 25.  Full regression: all previous stages (2-7) still pass

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/dataset'
require_relative '../lib/money'
require_relative '../lib/exchange_rates'
require_relative '../lib/recurrence'
require_relative '../lib/financial_engine'
require_relative '../lib/image_amount_extractor'
require_relative '../lib/unstructured_context'
require_relative '../lib/payment_planner'
require_relative '../lib/spending_changes'
require_relative '../lib/message_fact_extractor'
require_relative '../lib/output_validator'

puts '=================================================='
puts 'STAGE 8 OUTPUT VALIDATOR VERIFICATION'
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

def assert_errors_include(errors, substring, label)
  matched = errors.any? { |e| e.include?(substring) }
  if matched
    puts "  >> PASS: #{label}"
    true
  else
    puts "  >> FAIL: #{label} — expected error containing #{substring.inspect}"
    puts "           got errors: #{errors.inspect}"
    false
  end
end

# -------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------
REQ_DATE = '2026-06-01'
REQ_ID   = 'req_test'
REQ_AMT  = '10000'

def base_request(date: REQ_DATE, id: REQ_ID, amount: REQ_AMT, allows_partial: 'false')
  {
    'request_id'             => id,
    'user_id'                => 'u_test',
    'request_date'           => date,
    'requested_amount'       => amount,
    'desired_completion_date'=> (Date.parse(date) + 60).to_s,
    'allows_partial_payment' => allows_partial
  }
end

def base_profile
  {
    'user_id'                            => 'u_test',
    'home_currency'                      => 'USD',
    'current_available_balance'          => '50000',
    'minimum_balance_to_keep'            => '1000',
    'payment_methods_user_will_consider' => 'full_payment|installments|partial_payment'
  }
end

def empty_forecast(req_date = REQ_DATE, req_amt = REQ_AMT)
  FinancialEngine::ForecastResult.new(
    request_id:                    REQ_ID,
    user_id:                       'u_test',
    request_date:                  Date.parse(req_date),
    requested_amount:              Money.parse(req_amt),
    start_balance:                 Money.parse('50000'),
    min_balance:                   Money.parse('1000'),
    amount_safe_to_pay:            Money.parse(req_amt),
    affordability_status:          'affordable_now',
    earliest_date_for_full_payment: Date.parse(req_date),
    daily_balances:                {},
    recurring_streams:             [],
    extraction_warnings:           []
  )
end

def valid_full_payment_output(req_date: REQ_DATE, req_amt: REQ_AMT)
  {
    'request_id'                    => REQ_ID,
    'amount_safe_to_pay'            => Money.parse(req_amt),
    'affordability_status'          => 'affordable_now',
    'recommended_payment_method'    => 'full_payment',
    'payment_plan'                  => "#{req_date}:#{req_amt}",
    'earliest_date_for_full_payment'=> req_date,
    'spending_changes_needed'       => 'none',
    'decision_explanation'          => 'The user can pay in full today.'
  }
end

# Load real dataset once
profiles   = Dataset.load(:financial_profiles)
events     = Dataset.load(:financial_events)
samples    = Dataset.load(:sample_requests)
pay_opts   = Dataset.load(:request_payment_options)
images     = Dataset.load(:images)

profile_map     = profiles.each_with_object({}) { |p, h| h[p['user_id']] = p }
pay_opts_by_req = pay_opts.group_by { |o| o['request_id'] }
mock_provider   = ImageAmountExtractor::MockVisionProvider.new
extraction_cache = ImageAmountExtractor.build_cache(events, images, provider: mock_provider)

# ===========================================================================
# TEST 1: Valid affordable_now row passes
# ===========================================================================
puts "\n--- [TEST 1] Valid affordable_now / full_payment row passes ---"
out1 = valid_full_payment_output
errs1 = OutputValidator.validate(out1, base_request, base_profile, empty_forecast)
puts "  errors: #{errs1.inspect}"
if assert(errs1.empty?, 'Valid affordable_now full_payment produces no errors')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 2: Missing required field is detected
# ===========================================================================
puts "\n--- [TEST 2] Missing required field ---"
out2 = valid_full_payment_output.tap { |o| o.delete('payment_plan') }
errs2 = OutputValidator.validate(out2, base_request, base_profile, empty_forecast)
if assert_errors_include(errs2, 'payment_plan', 'Missing payment_plan field detected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 3: Invalid affordability_status enum
# ===========================================================================
puts "\n--- [TEST 3] Invalid affordability_status enum ---"
out3 = valid_full_payment_output.merge('affordability_status' => 'can_pay')
errs3 = OutputValidator.validate(out3, base_request, base_profile, empty_forecast)
if assert_errors_include(errs3, 'affordability_status', 'Invalid affordability_status rejected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 4: Invalid recommended_payment_method enum
# ===========================================================================
puts "\n--- [TEST 4] Invalid recommended_payment_method enum ---"
out4 = valid_full_payment_output.merge('recommended_payment_method' => 'maybe_pay')
errs4 = OutputValidator.validate(out4, base_request, base_profile, empty_forecast)
if assert_errors_include(errs4, 'recommended_payment_method', 'Invalid method enum rejected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 5: Float amount_safe_to_pay is rejected
# ===========================================================================
puts "\n--- [TEST 5] Float amount_safe_to_pay is rejected ---"
out5 = valid_full_payment_output.merge('amount_safe_to_pay' => 10000.0)  # Float!
errs5 = OutputValidator.validate(out5, base_request, base_profile, empty_forecast)
if assert_errors_include(errs5, 'BigDecimal', 'Float amount_safe_to_pay correctly rejected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 6: amount_safe_to_pay > requested_amount is rejected
# ===========================================================================
puts "\n--- [TEST 6] amount_safe_to_pay > requested_amount rejected ---"
out6 = valid_full_payment_output.merge('amount_safe_to_pay' => Money.parse('99999'))
errs6 = OutputValidator.validate(out6, base_request, base_profile, empty_forecast)
if assert_errors_include(errs6, 'requested_amount', 'amount_safe_to_pay > requested_amount detected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 7: Negative amount_safe_to_pay is rejected
# ===========================================================================
puts "\n--- [TEST 7] Negative amount_safe_to_pay rejected ---"
out7 = valid_full_payment_output.merge('amount_safe_to_pay' => Money.parse('-500'))
errs7 = OutputValidator.validate(out7, base_request, base_profile, empty_forecast)
if assert_errors_include(errs7, '>= 0', 'Negative amount_safe_to_pay detected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 8: Malformed payment_plan entry
# ===========================================================================
puts "\n--- [TEST 8] Malformed payment_plan entry (no colon) ---"
out8 = valid_full_payment_output.merge('payment_plan' => '2026-06-01-10000')
errs8 = OutputValidator.validate(out8, base_request, base_profile, empty_forecast)
if assert_errors_include(errs8, 'malformed', 'Malformed payment_plan entry detected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 9: Non-chronological payment_plan dates are rejected
# ===========================================================================
puts "\n--- [TEST 9] Non-chronological payment_plan dates ---"
out9 = valid_full_payment_output.merge(
  'recommended_payment_method' => 'installments',
  'affordability_status'       => 'affordable_with_plan',
  'payment_plan'               => '2026-07-01:5000|2026-06-01:5000'
)
errs9 = OutputValidator.validate(out9, base_request, base_profile, empty_forecast)
if assert_errors_include(errs9, 'chronological', 'Non-chronological payment_plan dates detected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 10: partial_payment amounts not summing to requested_amount
# ===========================================================================
puts "\n--- [TEST 10] partial_payment sum != requested_amount ---"
out10 = {
  'request_id'                     => REQ_ID,
  'amount_safe_to_pay'             => Money.parse('6000'),
  'affordability_status'           => 'affordable_with_plan',
  'recommended_payment_method'     => 'partial_payment',
  'payment_plan'                   => '2026-06-01:6000|2026-06-20:3000',   # sum=9000 != 10000
  'earliest_date_for_full_payment' => '2026-06-20',
  'spending_changes_needed'        => 'none',
  'decision_explanation'           => 'Partial payment plan.'
}
req10 = base_request(allows_partial: 'true')
errs10 = OutputValidator.validate(out10, req10, base_profile, empty_forecast)
if assert_errors_include(errs10, 'sum', 'partial_payment sum mismatch detected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 11: partial_payment with wrong number of entries
# ===========================================================================
puts "\n--- [TEST 11] partial_payment must have exactly 2 entries ---"
out11 = {
  'request_id'                     => REQ_ID,
  'amount_safe_to_pay'             => Money.parse('4000'),
  'affordability_status'           => 'affordable_with_plan',
  'recommended_payment_method'     => 'partial_payment',
  'payment_plan'                   => '2026-06-01:4000|2026-06-10:3000|2026-06-20:3000',  # 3 entries
  'earliest_date_for_full_payment' => '2026-06-20',
  'spending_changes_needed'        => 'none',
  'decision_explanation'           => 'Partial.'
}
errs11 = OutputValidator.validate(out11, base_request(allows_partial: 'true'), base_profile, empty_forecast)
if assert_errors_include(errs11, 'exactly 2', 'partial_payment 3-entry plan detected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 12: spending_changes_needed with 4 actions (exceeds max 3)
# ===========================================================================
puts "\n--- [TEST 12] spending_changes_needed with 4 actions rejected ---"
out12 = valid_full_payment_output.merge(
  'spending_changes_needed' => 'stop:event_01|stop:event_02|stop:event_03|stop:event_04'
)
errs12 = OutputValidator.validate(out12, base_request, base_profile, empty_forecast)
if assert_errors_include(errs12, 'at most 3', 'More than 3 spending changes detected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 13: spending_changes_needed with duplicate event_id (mutual exclusivity)
# ===========================================================================
puts "\n--- [TEST 13] spending_changes_needed duplicate event_id rejected ---"
out13 = valid_full_payment_output.merge(
  'spending_changes_needed' => 'stop:event_01|reduce_to:event_01:500'
)
errs13 = OutputValidator.validate(out13, base_request, base_profile, empty_forecast)
if assert_errors_include(errs13, 'mutual exclusivity', 'Duplicate event_id in spending changes detected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 14: reduce_to with non-positive amount rejected
# ===========================================================================
puts "\n--- [TEST 14] reduce_to with negative/zero amount rejected ---"
out14 = valid_full_payment_output.merge(
  'spending_changes_needed' => 'reduce_to:event_01:0'
)
errs14 = OutputValidator.validate(out14, base_request, base_profile, empty_forecast)
if assert_errors_include(errs14, 'positive', 'reduce_to with zero amount detected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 15: affordable_now + spending changes is rejected
# ===========================================================================
puts "\n--- [TEST 15] affordable_now + spending_changes_needed rejected ---"
out15 = valid_full_payment_output.merge(
  'spending_changes_needed' => 'stop:event_01'
)
errs15 = OutputValidator.validate(out15, base_request, base_profile, empty_forecast)
if assert_errors_include(errs15, 'spending_changes_needed=none', 'affordable_now with spending changes detected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 16: affordable_now without full_payment method is rejected
# ===========================================================================
puts "\n--- [TEST 16] affordable_now without full_payment method rejected ---"
out16 = valid_full_payment_output.merge('recommended_payment_method' => 'installments')
errs16 = OutputValidator.validate(out16, base_request, base_profile, empty_forecast)
if assert_errors_include(errs16, 'full_payment', 'affordable_now without full_payment detected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 17: affordable_later without wait method is rejected
# ===========================================================================
puts "\n--- [TEST 17] affordable_later without wait method rejected ---"
fc17 = empty_forecast
out17 = {
  'request_id'                     => REQ_ID,
  'amount_safe_to_pay'             => Money::ZERO,
  'affordability_status'           => 'affordable_later',
  'recommended_payment_method'     => 'full_payment',  # wrong!
  'payment_plan'                   => '2026-06-01:10000',
  'earliest_date_for_full_payment' => '2026-06-20',
  'spending_changes_needed'        => 'none',
  'decision_explanation'           => 'Later.'
}
errs17 = OutputValidator.validate(out17, base_request, base_profile, fc17)
if assert_errors_include(errs17, 'wait', 'affordable_later without wait detected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 18: not_recommended with non-none payment_plan is rejected
# ===========================================================================
puts "\n--- [TEST 18] not_recommended with payment_plan != none rejected ---"
out18 = {
  'request_id'                     => REQ_ID,
  'amount_safe_to_pay'             => Money::ZERO,
  'affordability_status'           => 'not_affordable',
  'recommended_payment_method'     => 'not_recommended',
  'payment_plan'                   => '2026-06-01:10000',   # should be 'none'
  'earliest_date_for_full_payment' => '',
  'spending_changes_needed'        => 'none',
  'decision_explanation'           => 'Cannot afford.'
}
errs18 = OutputValidator.validate(out18, base_request, base_profile, empty_forecast)
if assert_errors_include(errs18, 'none', 'not_recommended with non-none payment_plan detected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 19: wait without earliest_date_for_full_payment is rejected
# ===========================================================================
puts "\n--- [TEST 19] wait without earliest_date_for_full_payment rejected ---"
out19 = {
  'request_id'                     => REQ_ID,
  'amount_safe_to_pay'             => Money::ZERO,
  'affordability_status'           => 'affordable_later',
  'recommended_payment_method'     => 'wait',
  'payment_plan'                   => 'none',
  'earliest_date_for_full_payment' => '',   # missing!
  'spending_changes_needed'        => 'none',
  'decision_explanation'           => 'Wait.'
}
errs19 = OutputValidator.validate(out19, base_request, base_profile, empty_forecast)
if assert_errors_include(errs19, 'earliest_date_for_full_payment', 'wait without earliest date detected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 20: wait where earliest <= request_date is rejected
# ===========================================================================
puts "\n--- [TEST 20] wait where earliest <= request_date rejected ---"
out20 = {
  'request_id'                     => REQ_ID,
  'amount_safe_to_pay'             => Money::ZERO,
  'affordability_status'           => 'affordable_later',
  'recommended_payment_method'     => 'wait',
  'payment_plan'                   => '2026-06-01:10000',
  'earliest_date_for_full_payment' => '2026-06-01',  # == request_date, not >
  'spending_changes_needed'        => 'none',
  'decision_explanation'           => 'Wait.'
}
errs20 = OutputValidator.validate(out20, base_request, base_profile, empty_forecast)
if assert_errors_include(errs20, 'request_date', 'wait with earliest == request_date detected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 21: full_payment where amount_safe_to_pay < requested_amount
# ===========================================================================
puts "\n--- [TEST 21] full_payment where amount_safe_to_pay < requested_amount ---"
out21 = valid_full_payment_output.merge('amount_safe_to_pay' => Money.parse('5000'))
errs21 = OutputValidator.validate(out21, base_request, base_profile, empty_forecast)
if assert_errors_include(errs21, 'requested_amount', 'full_payment with insufficient amount detected')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 22: payment_plan=none for full_payment method is rejected
# ===========================================================================
puts "\n--- [TEST 22] payment_plan=none for full_payment method rejected ---"
out22 = valid_full_payment_output.merge('payment_plan' => 'none')
errs22 = OutputValidator.validate(out22, base_request, base_profile, empty_forecast)
if assert_errors_include(errs22, 'full_payment', "payment_plan='none' for full_payment detected")
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 23: Real sample request_01 passes validation
# ===========================================================================
puts "\n--- [TEST 23] Real sample request_01 passes validation ---"
r01  = samples.find { |r| r['request_id'] == 'request_01' }
p01  = profile_map[r01['user_id']]
fc01 = FinancialEngine.evaluate_request(r01, p01, events, extraction_cache: extraction_cache)
opts01 = pay_opts_by_req['request_01'] || []
res01 = PaymentPlanner.select_plan(r01, p01, fc01, opts01)

# Build output hash as main.rb would
out23 = {
  'request_id'                     => r01['request_id'],
  'amount_safe_to_pay'             => fc01.amount_safe_to_pay,
  'affordability_status'           => res01[:affordability_status],
  'recommended_payment_method'     => res01[:recommended_payment_method],
  'payment_plan'                   => res01[:payment_plan],
  'earliest_date_for_full_payment' => fc01.earliest_date_for_full_payment&.to_s || '',
  'spending_changes_needed'        => res01[:spending_changes_needed],
  'decision_explanation'           => "#{res01[:recommended_payment_method].upcase}: #{res01[:affordability_status]}"
}
errs23 = OutputValidator.validate(out23, r01, p01, fc01)
puts "  method=#{out23['recommended_payment_method']} status=#{out23['affordability_status']}"
puts "  errors: #{errs23.inspect}"
if assert(errs23.empty?, 'request_01 real output passes validator')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 24: Real sample request_22 (installments) passes validation
# ===========================================================================
puts "\n--- [TEST 24] Real sample request_22 (installments) passes validation ---"
r22  = samples.find { |r| r['request_id'] == 'request_22' }
p22  = profile_map[r22['user_id']]
fc22 = FinancialEngine.evaluate_request(r22, p22, events, extraction_cache: extraction_cache)
opts22 = pay_opts_by_req['request_22'] || []
res22 = PaymentPlanner.select_plan(r22, p22, fc22, opts22)

out24 = {
  'request_id'                     => r22['request_id'],
  'amount_safe_to_pay'             => fc22.amount_safe_to_pay,
  'affordability_status'           => res22[:affordability_status],
  'recommended_payment_method'     => res22[:recommended_payment_method],
  'payment_plan'                   => res22[:payment_plan],
  'earliest_date_for_full_payment' => fc22.earliest_date_for_full_payment&.to_s || '',
  'spending_changes_needed'        => res22[:spending_changes_needed],
  'decision_explanation'           => "#{res22[:recommended_payment_method].upcase}: #{res22[:affordability_status]}"
}
errs24 = OutputValidator.validate(out24, r22, p22, fc22)
puts "  method=#{out24['recommended_payment_method']} status=#{out24['affordability_status']}"
puts "  plan=#{out24['payment_plan']}"
puts "  errors: #{errs24.inspect}"
if assert(errs24.empty?, 'request_22 real installment output passes validator')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# TEST 25: Full regression — all previous stages still pass
# ===========================================================================
puts "\n--- [TEST 25] Stage 2-7 regression ---"
stage7_ok = system('ruby', File.expand_path('../bin/verify_stage7.rb', __dir__), out: File::NULL, err: File::NULL)
if assert(stage7_ok, 'All Stage 2-7 verification tests still pass (verify_stage7.rb exits 0)')
  pass_count += 1
else
  fail_count += 1
end

# ===========================================================================
# Summary
# ===========================================================================
total = pass_count + fail_count
puts "\n=================================================="
puts "STAGE 8 RESULTS: #{pass_count}/#{total} PASSED"
puts '=================================================='

if fail_count > 0
  puts "#{fail_count} test(s) FAILED."
  exit 1
else
  puts 'ALL STAGE 8 TESTS PASSED.'
  exit 0
end
