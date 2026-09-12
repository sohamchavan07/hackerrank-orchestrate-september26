#!/usr/bin/env ruby
# frozen_string_literal: true

# verify_stage5.rb — Stage 5 Payment Method + Plan Selection Verification
#
# Tests:
#  1.  full_payment selected when safe today and user accepts it
#  2.  full_payment NOT selected when user rejects it
#  3.  installments selected when safe and user accepts (check plan string format)
#  4.  installments rejected when number_of_payments > max_installment_months
#  5.  installments rejected when max_installment_months is nil (user won't consider)
#  6.  installment safety check rejects unsafe schedule (breaches min_bal)
#  7.  installment safety check passes safe schedule
#  8.  partial_payment selected when allowed and eligible
#  9.  partial_payment NOT selected when allows_partial_payment = false
# 10.  wait selected when full amount affordable later and user accepts full_payment
# 11.  wait NOT selected when user doesn't accept full_payment
# 12.  not_recommended when nothing is eligible/safe
# 13.  ranking: on-time plan preferred over plan that misses deadline
# 14.  ranking: lower total cost wins among same-deadline candidates
# 15.  ranking: earlier start wins when cost is equal
# 16.  ranking: fewer payments wins when start is equal
# 17.  ranking: installments update affordability_status to affordable_with_plan
# 18.  affordability_status stays affordable_later when wait is chosen
# 19.  affordability_status set to affordable_now when full_payment chosen
# 20.  Real sample request_01 (full_payment): method + plan correct
# 21.  Real sample request_22 (installments): method + 3-installment plan correct
# 22.  Stage 2–4 regression: all previous tests still pass

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/dataset'
require_relative '../lib/money'
require_relative '../lib/exchange_rates'
require_relative '../lib/recurrence'
require_relative '../lib/financial_engine'
require_relative '../lib/image_amount_extractor'
require_relative '../lib/unstructured_context'
require_relative '../lib/payment_planner'

puts '=================================================='
puts 'STAGE 5 PAYMENT PLAN SELECTION VERIFICATION'
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

# Shared real dataset
requests   = Dataset.load(:requests)
samples    = Dataset.load(:sample_requests)
profiles   = Dataset.load(:financial_profiles)
events     = Dataset.load(:financial_events)
images     = Dataset.load(:images)
pay_opts   = Dataset.load(:request_payment_options)

profile_map = profiles.each_with_object({}) { |p, h| h[p['user_id']] = p }
pay_opts_by_req = pay_opts.group_by { |o| o['request_id'] }

mock_provider    = ImageAmountExtractor::MockVisionProvider.new
extraction_cache = ImageAmountExtractor.build_cache(events, images, provider: mock_provider)

# Helpers to build synthetic forecast + request data
def syn_forecast(req_date_str, req_amt_str, safe_str, earliest_str, min_bal_str, daily_bal_override = {})
  req_date  = Date.parse(req_date_str)
  req_amt   = Money.parse(req_amt_str)
  safe_amt  = Money.parse(safe_str)
  earliest  = earliest_str ? Date.parse(earliest_str) : nil
  min_bal   = Money.parse(min_bal_str)

  # Build a simple daily_balances: start at (safe+min), no flows
  start_bal = safe_amt + min_bal
  daily_bals = {}
  (0..90).each do |off|
    d = req_date + off
    daily_bals[d] = daily_bal_override[off] || start_bal
  end

  FinancialEngine::ForecastResult.new(
    request_id: 'syn',
    user_id: 'u_syn',
    request_date: req_date,
    requested_amount: req_amt,
    start_balance: start_bal,
    min_balance: min_bal,
    amount_safe_to_pay: safe_amt,
    affordability_status: 'not_affordable',
    earliest_date_for_full_payment: earliest,
    daily_balances: daily_bals,
    recurring_streams: [],
    extraction_warnings: []
  )
end

def syn_profile(methods, max_installment_months = nil)
  {
    'user_id'                           => 'u_syn',
    'home_currency'                     => 'INR',
    'current_available_balance'         => '100000',
    'minimum_balance_to_keep'           => '10000',
    'payment_methods_user_will_consider' => methods,
    'max_installment_months'            => max_installment_months&.to_s
  }
end

def syn_request(req_date, req_amt, desired, allows_partial = false)
  {
    'request_id'              => 'syn',
    'user_id'                 => 'u_syn',
    'request_date'            => req_date,
    'requested_amount'        => req_amt,
    'desired_completion_date' => desired,
    'allows_partial_payment'  => allows_partial.to_s
  }
end

# Build an installment payment option row
def syn_install_opt(n, first, freq, pmt, total, method = 'installments', opt_id = 'opt_01')
  {
    'payment_option_id'      => opt_id,
    'request_id'             => 'syn',
    'payment_method'         => method,
    'payment_amount'         => pmt,
    'number_of_payments'     => n.to_s,
    'first_payment_date'     => first,
    'payment_frequency_days' => freq.to_s,
    'financing_fee'          => '0',
    'total_payable_amount'   => total
  }
end

def syn_full_opt(date_str, amt_str)
  {
    'payment_option_id'      => 'opt_fp',
    'request_id'             => 'syn',
    'payment_method'         => 'full_payment',
    'payment_amount'         => amt_str,
    'number_of_payments'     => '1',
    'first_payment_date'     => date_str,
    'payment_frequency_days' => nil,
    'financing_fee'          => '0',
    'total_payable_amount'   => amt_str
  }
end

# ---------------------------------------------------------------------------
# TEST 1: full_payment selected when safe and user accepts
# ---------------------------------------------------------------------------
puts "\n--- [TEST 1] full_payment selected when safe today ---"
fc1  = syn_forecast('2026-06-01', '5000', '5000', '2026-06-01', '1000')
req1 = syn_request('2026-06-01', '5000', '2026-06-30')
prof1 = syn_profile('full_payment')
opts1 = [syn_full_opt('2026-06-01', '5000')]
res1  = PaymentPlanner.select_plan(req1, prof1, fc1, opts1)

t1 = res1[:recommended_payment_method] == 'full_payment' &&
     res1[:payment_plan] == '2026-06-01:5000' &&
     res1[:affordability_status] == 'affordable_now'
puts "  method=#{res1[:recommended_payment_method]} plan=#{res1[:payment_plan]} status=#{res1[:affordability_status]}"
if assert(t1, 'full_payment chosen when safe, user accepts, correct plan string')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 2: full_payment NOT chosen when user rejects it
# ---------------------------------------------------------------------------
puts "\n--- [TEST 2] full_payment NOT chosen when user rejects ---"
prof2 = syn_profile('installments', 12)
res2  = PaymentPlanner.select_plan(req1, prof2, fc1, opts1)

t2 = res2[:recommended_payment_method] == 'not_recommended'
puts "  method=#{res2[:recommended_payment_method]} (exp not_recommended, no installments options given)"
if assert(t2, 'full_payment not selected when user only considers installments')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 3: installments selected when safe, with correct plan string
# ---------------------------------------------------------------------------
puts "\n--- [TEST 3] installments selected when safe ---"
# 3 payments of 1000, every 30 days from 2026-06-05; total = 3000; daily_bal = 5000, min_bal = 1000
# After all 3 payments: 5000-3000=2000 >= 1000 => SAFE
# safe=4000 => daily_bal = safe + min_bal = 4000 + 1000 = 5000
fc3   = syn_forecast('2026-06-01', '3000', '4000', nil, '1000')
req3  = syn_request('2026-06-01', '3000', '2026-09-30')
prof3 = syn_profile('installments', 12)
opts3 = [
  syn_full_opt('2026-06-01', '3000'),
  syn_install_opt(3, '2026-06-05', 30, '1000', '3000')
]
res3 = PaymentPlanner.select_plan(req3, prof3, fc3, opts3)

t3 = res3[:recommended_payment_method] == 'installments' &&
     res3[:payment_plan] == '2026-06-05:1000|2026-07-05:1000|2026-08-04:1000' &&
     res3[:affordability_status] == 'affordable_with_plan'
puts "  method=#{res3[:recommended_payment_method]}"
puts "  plan=#{res3[:payment_plan]}"
puts "  status=#{res3[:affordability_status]}"
if assert(t3, 'installments plan string is correct (date offsets, amount preserved, status updated)')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 4: installments rejected when number_of_payments > max_installment_months
# ---------------------------------------------------------------------------
puts "\n--- [TEST 4] installments rejected when n > max_installment_months ---"
prof4 = syn_profile('installments', 2)  # max = 2, but option has n=3
res4  = PaymentPlanner.select_plan(req3, prof4, fc3, opts3)

t4 = res4[:recommended_payment_method] == 'not_recommended'
puts "  method=#{res4[:recommended_payment_method]} (exp not_recommended)"
if assert(t4, 'installment option with n=3 rejected when max_installment_months=2')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 5: installments rejected when max_installment_months is nil/blank
# ---------------------------------------------------------------------------
puts "\n--- [TEST 5] installments rejected when max_installment_months is nil ---"
prof5 = syn_profile('installments', nil)
res5  = PaymentPlanner.select_plan(req3, prof5, fc3, opts3)

t5 = res5[:recommended_payment_method] == 'not_recommended'
puts "  method=#{res5[:recommended_payment_method]} (exp not_recommended)"
if assert(t5, 'installments skipped entirely when max_installment_months is nil')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 6: installment safety check rejects unsafe schedule
# ---------------------------------------------------------------------------
puts "\n--- [TEST 6] installment safety check rejects unsafe plan ---"
# Balance = 2000, min_bal = 1000, installments of 1500 each
# After first payment: 2000-1500 = 500 < 1000 => UNSAFE
unsafe_daily = {}
(0..90).each { |i| unsafe_daily[i] = Money.parse('2000') }
fc6 = FinancialEngine::ForecastResult.new(
  request_id: 'syn', user_id: 'u_syn',
  request_date: Date.parse('2026-06-01'),
  requested_amount: Money.parse('3000'),
  start_balance: Money.parse('2000'),
  min_balance: Money.parse('1000'),
  amount_safe_to_pay: Money::ZERO,
  affordability_status: 'not_affordable',
  earliest_date_for_full_payment: nil,
  daily_balances: (0..90).each_with_object({}) { |i, h| h[Date.parse('2026-06-01') + i] = Money.parse('2000') },
  recurring_streams: [],
  extraction_warnings: []
)
req6 = syn_request('2026-06-01', '3000', '2026-09-30')
prof6 = syn_profile('installments', 12)
opts6 = [syn_install_opt(3, '2026-06-05', 30, '1500', '4500')]
res6  = PaymentPlanner.select_plan(req6, prof6, fc6, opts6)

t6 = res6[:recommended_payment_method] == 'not_recommended'
puts "  method=#{res6[:recommended_payment_method]} (exp not_recommended, balance breach)"
if assert(t6, 'Unsafe installment (breaches min_bal after first payment) correctly rejected')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 7: installment safety check passes safe schedule
# ---------------------------------------------------------------------------
puts "\n--- [TEST 7] installment safety check passes safe plan ---"
# Balance = 5000, min_bal = 1000, 3 x 1000 installments => min remaining = 5000-3000 = 2000 >= 1000
fc7 = FinancialEngine::ForecastResult.new(
  request_id: 'syn', user_id: 'u_syn',
  request_date: Date.parse('2026-06-01'),
  requested_amount: Money.parse('3000'),
  start_balance: Money.parse('5000'),
  min_balance: Money.parse('1000'),
  amount_safe_to_pay: Money::ZERO,
  affordability_status: 'not_affordable',
  earliest_date_for_full_payment: nil,
  daily_balances: (0..90).each_with_object({}) { |i, h| h[Date.parse('2026-06-01') + i] = Money.parse('5000') },
  recurring_streams: [],
  extraction_warnings: []
)
opts7 = [syn_install_opt(3, '2026-06-05', 30, '1000', '3000')]
res7  = PaymentPlanner.select_plan(req3, syn_profile('installments', 12), fc7, opts7)

t7 = res7[:recommended_payment_method] == 'installments'
puts "  method=#{res7[:recommended_payment_method]} (exp installments)"
if assert(t7, 'Safe installment schedule (3x1000 with balance=5000, min=1000) accepted')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 8: partial_payment selected when eligible
# ---------------------------------------------------------------------------
puts "\n--- [TEST 8] partial_payment selected when eligible ---"
fc8  = syn_forecast('2026-06-01', '10000', '6000', '2026-06-20', '2000')
req8 = syn_request('2026-06-01', '10000', '2026-07-01', true)
prof8 = syn_profile('partial_payment')
res8  = PaymentPlanner.select_plan(req8, prof8, fc8, [])

t8 = res8[:recommended_payment_method] == 'partial_payment' &&
     res8[:payment_plan].include?('2026-06-01:6000') &&
     res8[:payment_plan].include?('2026-06-20:4000') &&
     res8[:affordability_status] == 'affordable_with_plan'
puts "  method=#{res8[:recommended_payment_method]} plan=#{res8[:payment_plan]} status=#{res8[:affordability_status]}"
if assert(t8, 'partial_payment with two correct payment dates and amounts')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 9: partial_payment NOT selected when allows_partial_payment = false
# ---------------------------------------------------------------------------
puts "\n--- [TEST 9] partial_payment NOT selected when allows_partial_payment=false ---"
req9 = syn_request('2026-06-01', '10000', '2026-07-01', false)
res9 = PaymentPlanner.select_plan(req9, prof8, fc8, [])

t9 = res9[:recommended_payment_method] == 'not_recommended'
puts "  method=#{res9[:recommended_payment_method]} (exp not_recommended)"
if assert(t9, 'partial_payment correctly blocked when allows_partial_payment=false')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 10: wait selected when amount affordable later and user accepts full_payment
# ---------------------------------------------------------------------------
puts "\n--- [TEST 10] wait selected when affordable later and user accepts full_payment ---"
fc10  = syn_forecast('2026-06-01', '5000', '0', '2026-06-20', '1000')
req10 = syn_request('2026-06-01', '5000', '2026-07-01')
prof10 = syn_profile('full_payment')
opts10 = [syn_full_opt('2026-06-01', '5000')]
res10 = PaymentPlanner.select_plan(req10, prof10, fc10, opts10)

t10 = res10[:recommended_payment_method] == 'wait' &&
      res10[:payment_plan] == '2026-06-20:5000' &&
      res10[:affordability_status] == 'affordable_later'
puts "  method=#{res10[:recommended_payment_method]} plan=#{res10[:payment_plan]} status=#{res10[:affordability_status]}"
if assert(t10, 'wait selected correctly with plan date=earliest_date:amount, status=affordable_later')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 11: wait NOT selected when user doesn't consider full_payment
# ---------------------------------------------------------------------------
puts "\n--- [TEST 11] wait NOT selected when user doesn't accept full_payment ---"
prof11 = syn_profile('installments', 12)
res11  = PaymentPlanner.select_plan(req10, prof11, fc10, [])

t11 = res11[:recommended_payment_method] == 'not_recommended'
puts "  method=#{res11[:recommended_payment_method]} (exp not_recommended)"
if assert(t11, 'wait not selected when user only considers installments')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 12: not_recommended when nothing is eligible/safe
# ---------------------------------------------------------------------------
puts "\n--- [TEST 12] not_recommended when nothing safe or eligible ---"
fc12  = syn_forecast('2026-06-01', '100000', '0', nil, '5000')
req12 = syn_request('2026-06-01', '100000', '2026-06-30')
prof12 = syn_profile('full_payment|installments', 12)
opts12 = [
  syn_full_opt('2026-06-01', '100000'),
  syn_install_opt(3, '2026-06-05', 30, '40000', '120000')  # 40000+40000+40000 > 6000 daily bal => unsafe
]
res12 = PaymentPlanner.select_plan(req12, prof12, fc12, opts12)

t12 = res12[:recommended_payment_method] == 'not_recommended' &&
      res12[:payment_plan] == 'none'
puts "  method=#{res12[:recommended_payment_method]} plan=#{res12[:payment_plan]}"
if assert(t12, 'not_recommended returned when no plan is safe/eligible')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 13: Ranking — on-time plan preferred over one that misses deadline
# ---------------------------------------------------------------------------
puts "\n--- [TEST 13] Ranking: on-time plan preferred over plan missing deadline ---"
# desired = 2026-06-25
# Option A: 1 payment on 2026-06-20 (on time, <= desired), total = 3200 (more expensive)
# Option B: 1 payment on 2026-06-30 (misses desired 2026-06-25), total = 2900 (cheaper but late)
# On-time option A must win despite higher cost
req13 = syn_request('2026-06-01', '3000', '2026-06-25')
prof13 = syn_profile('installments', 12)
opts13 = [
  syn_install_opt(1, '2026-06-20', 0, '3200', '3200', 'installments', 'opt_ontime'),
  syn_install_opt(1, '2026-06-30', 0, '2900', '2900', 'installments', 'opt_late')
]
fc13_rich = FinancialEngine::ForecastResult.new(
  request_id: 'syn', user_id: 'u_syn',
  request_date: Date.parse('2026-06-01'),
  requested_amount: Money.parse('3000'),
  start_balance: Money.parse('10000'),
  min_balance: Money.parse('500'),
  amount_safe_to_pay: Money::ZERO,
  affordability_status: 'not_affordable',
  earliest_date_for_full_payment: nil,
  daily_balances: (0..90).each_with_object({}) { |i, h| h[Date.parse('2026-06-01') + i] = Money.parse('10000') },
  recurring_streams: [],
  extraction_warnings: []
)
res13 = PaymentPlanner.select_plan(req13, prof13, fc13_rich, opts13)

t13 = res13[:recommended_payment_method] == 'installments' &&
      res13[:payment_plan] == '2026-06-20:3200'
puts "  method=#{res13[:recommended_payment_method]} plan=#{res13[:payment_plan]}"
puts "  expected: installments, 2026-06-20:3200 (on-time despite higher cost)"
if assert(t13, 'On-time plan (payment 2026-06-20 <= desired 2026-06-25) chosen over cheaper late plan (2026-06-30)')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 14: Ranking — lower total cost wins among same-deadline candidates
# ---------------------------------------------------------------------------
puts "\n--- [TEST 14] Ranking: lower total cost wins among on-time candidates ---"
opts14 = [
  syn_install_opt(3, '2026-06-01', 25, '1000', '3000', 'installments', 'opt_expensive'),
  syn_install_opt(3, '2026-06-01', 25, '900',  '2700', 'installments', 'opt_cheap')
]
res14 = PaymentPlanner.select_plan(req13, prof13, fc13_rich, opts14)

t14 = res14[:recommended_payment_method] == 'installments' &&
      res14[:payment_plan].include?('900')
puts "  plan=#{res14[:payment_plan]} (exp 900-per-payment option wins)"
if assert(t14, 'Cheaper plan (total=2700) chosen over expensive (3000) when both on-time')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 15: Ranking — earlier start wins when cost is equal
# ---------------------------------------------------------------------------
puts "\n--- [TEST 15] Ranking: earlier start wins when total cost equal ---"
opts15 = [
  syn_install_opt(3, '2026-06-05', 20, '1000', '3000', 'installments', 'opt_later'),
  syn_install_opt(3, '2026-06-02', 20, '1000', '3000', 'installments', 'opt_earlier')
]
res15 = PaymentPlanner.select_plan(req13, prof13, fc13_rich, opts15)

t15 = res15[:payment_plan].start_with?('2026-06-02')
puts "  plan starts with: #{res15[:payment_plan][0..10]} (exp 2026-06-02)"
if assert(t15, 'Earlier start date (2026-06-02) wins when cost equal')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 16: Ranking — fewer payments wins when start and cost equal
# ---------------------------------------------------------------------------
puts "\n--- [TEST 16] Ranking: fewer payments wins ---"
opts16 = [
  syn_install_opt(6, '2026-06-02', 10, '500', '3000', 'installments', 'opt_6pmt'),
  syn_install_opt(3, '2026-06-02', 20, '1000', '3000', 'installments', 'opt_3pmt')
]
res16 = PaymentPlanner.select_plan(req13, prof13, fc13_rich, opts16)

t16 = res16[:payment_plan].split('|').size == 3  # 3 payments (not 6)
puts "  payments in plan: #{res16[:payment_plan].split('|').size} (exp 3)"
if assert(t16, 'Plan with fewer payments (3 vs 6) wins when start and total equal')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 17: installments update affordability_status to affordable_with_plan
# ---------------------------------------------------------------------------
puts "\n--- [TEST 17] affordability_status updated to affordable_with_plan for installments ---"
# fc with affordability_status = 'not_affordable', but installments are safe
res17 = PaymentPlanner.select_plan(req3, syn_profile('installments', 12), fc7, opts7)

t17 = res17[:affordability_status] == 'affordable_with_plan'
puts "  status=#{res17[:affordability_status]} (exp affordable_with_plan)"
if assert(t17, 'affordability_status updated to affordable_with_plan when installments selected')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 18: affordability_status stays affordable_later for wait
# ---------------------------------------------------------------------------
puts "\n--- [TEST 18] affordability_status stays affordable_later for wait ---"
t18 = res10[:affordability_status] == 'affordable_later'
puts "  status=#{res10[:affordability_status]} (exp affordable_later)"
if assert(t18, 'affordability_status stays affordable_later when wait is chosen')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 19: affordability_status set to affordable_now for full_payment
# ---------------------------------------------------------------------------
puts "\n--- [TEST 19] affordability_status = affordable_now for full_payment ---"
t19 = res1[:affordability_status] == 'affordable_now'
puts "  status=#{res1[:affordability_status]} (exp affordable_now)"
if assert(t19, 'affordability_status = affordable_now when full_payment is chosen')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 20: Real sample request_01 (full_payment)
# ---------------------------------------------------------------------------
puts "\n--- [TEST 20] Real request_01: full_payment method + plan ---"
r01  = samples.find { |r| r['request_id'] == 'request_01' }
p01  = profile_map[r01['user_id']]
fc01 = FinancialEngine.evaluate_request(r01, p01, events, extraction_cache: extraction_cache)
opts01 = pay_opts_by_req['request_01'] || []
res20 = PaymentPlanner.select_plan(r01, p01, fc01, opts01)

exp_method20 = r01['recommended_payment_method']   # 'full_payment'
exp_plan20   = r01['payment_plan']                  # '2024-03-03:25256'

puts "  method: #{res20[:recommended_payment_method]} (exp #{exp_method20})"
puts "  plan:   #{res20[:payment_plan]} (exp #{exp_plan20})"

t20 = res20[:recommended_payment_method] == exp_method20 &&
      res20[:payment_plan] == exp_plan20
if assert(t20, 'request_01: full_payment selected with correct plan string')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 21: Real sample request_22 (installments, 3 payments)
# ---------------------------------------------------------------------------
puts "\n--- [TEST 21] Real request_22: installments, 3-payment plan ---"
r22  = samples.find { |r| r['request_id'] == 'request_22' }
p22  = profile_map[r22['user_id']]
fc22 = FinancialEngine.evaluate_request(r22, p22, events, extraction_cache: extraction_cache)
opts22 = pay_opts_by_req['request_22'] || []
res21 = PaymentPlanner.select_plan(r22, p22, fc22, opts22)

exp_method21 = r22['recommended_payment_method']   # 'installments'
exp_plan21   = r22['payment_plan']                  # '2024-12-08:253.59|2025-01-05:253.59|2025-02-02:253.59'

puts "  method: #{res21[:recommended_payment_method]} (exp #{exp_method21})"
puts "  plan:   #{res21[:payment_plan]}"
puts "  exp:    #{exp_plan21}"

t21 = res21[:recommended_payment_method] == exp_method21 &&
      res21[:payment_plan] == exp_plan21
if assert(t21, 'request_22: installments with 3-payment plan matches sample exactly')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 22: Stage 2–4 regression via verify_stage4 exit
# ---------------------------------------------------------------------------
puts "\n--- [TEST 22] Stage 2-4 regression ---"
stage4_ok = system('ruby', File.expand_path('../bin/verify_stage4.rb', __dir__), out: File::NULL, err: File::NULL)
if assert(stage4_ok, 'All Stage 2-4 verification tests still pass (verify_stage4.rb exits 0)')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
total = pass_count + fail_count
puts "\n=================================================="
puts "STAGE 5 RESULTS: #{pass_count}/#{total} PASSED"
puts '=================================================='

if fail_count > 0
  puts "#{fail_count} test(s) FAILED."
  exit 1
else
  puts 'ALL STAGE 5 TESTS PASSED.'
  exit 0
end
