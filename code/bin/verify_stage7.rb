#!/usr/bin/env ruby
# frozen_string_literal: true

# verify_stage7.rb — Stage 7: Deterministic Spending Changes Needed Verification
#
# Tests:
#  1. Flexible recurring expense can be stopped and future occurrences disappear
#  2. Flexible recurring expense can be reduced to a lower amount
#  3. Essential/fixed expenses are never proposed
#  4. One-off expenses are never proposed
#  5. stop and reduce_to are never emitted together for the same event
#  6. Reduction amount must be strictly lower than existing recurring amount
#  7. Invalid/nonexistent event IDs cannot be emitted
#  8. Maximum 3 spending changes is enforced
#  9. Proposed spending change must actually make the financial plan safe
# 10. Spending change that still leaves minimum balance violated is rejected
# 11. Existing Stage 5 plans with no spending changes continue to work unchanged
# 12. Deterministic tie-breaking produces the same result on repeated runs
# 13. Real dataset flexible recurring expenses and sample requests verification
# 14. Full regression: all previous stages (Stages 2, 3, 4, 5, 6) still pass

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

puts '=================================================='
puts 'STAGE 7 SPENDING CHANGES VERIFICATION'
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

# Load real dataset
events   = Dataset.load(:financial_events)
profiles = Dataset.load(:financial_profiles)
requests = Dataset.load(:requests)
samples  = Dataset.load(:sample_requests)
pay_opts = Dataset.load(:request_payment_options)
messages = Dataset.load(:messages)

profile_map = profiles.each_with_object({}) { |p, h| h[p['user_id']] = p }
pay_opts_by_req = pay_opts.group_by { |o| o['request_id'] }

# ---------------------------------------------------------------------------
# TEST 1: Flexible recurring expense can be stopped
# ---------------------------------------------------------------------------
puts "\n--- [TEST 1] Flexible recurring expense can be stopped ---"
# Setup: user needs 1000 today, available balance is 1100, min_bal is 100.
# Has a recurring streaming subscription of 200/mo on day 10, stoppable.
# Without stopping it, balance drops to 1100 - 600 - 1000 < 100 (unsafe).
# Stopping it removes future occurrences, leaving 1100 - 1000 = 100 >= min_bal (safe).
req1 = {
  'request_id' => 'req_t1', 'user_id' => 'u_t1', 'request_date' => '2026-06-01',
  'requested_amount' => '1000', 'desired_completion_date' => '2026-06-15', 'allows_partial_payment' => 'false'
}
prof1 = {
  'user_id' => 'u_t1', 'home_currency' => 'USD', 'current_available_balance' => '1100',
  'minimum_balance_to_keep' => '100', 'payment_methods_user_will_consider' => 'full_payment',
  'expense_categories_to_protect' => 'rent|utilities',
  'expense_categories_user_is_willing_to_stop' => 'streaming',
  'expense_categories_user_is_willing_to_reduce' => ''
}
ev_sub1 = {
  'event_id' => 'event_sub_01', 'user_id' => 'u_t1', 'event_type' => 'subscription',
  'category' => 'streaming', 'direction' => 'debit', 'amount' => '200', 'currency' => 'USD',
  'event_date' => '2026-05-10', 'settlement_date' => '2026-05-10', 'status' => 'settled',
  'flexibility' => 'stoppable', 'minimum_allowed_amount' => nil, 'description' => 'Streaming'
}
stream1 = Recurrence::RecurringStream.new(
  name: 'Streaming', category: 'streaming', event_type: 'subscription',
  amount: Money.parse('200'), currency: 'USD', cadence: :monthly,
  day_of_month: 10, anchor_date: Date.parse('2026-05-10'), last_event_id: 'event_sub_01', is_income: false
)
opts1 = [{
  'payment_option_id' => 'opt_fp', 'request_id' => 'req_t1', 'payment_method' => 'full_payment',
  'payment_amount' => '1000', 'number_of_payments' => '1', 'first_payment_date' => '2026-06-01',
  'total_payable_amount' => '1000'
}]

fc1 = FinancialEngine.evaluate_request(req1, prof1, [ev_sub1], recurring_streams_override: [stream1])
res1 = PaymentPlanner.select_plan(req1, prof1, fc1, opts1, events: [ev_sub1])

t1 = res1[:recommended_payment_method] == 'full_payment' &&
     res1[:spending_changes_needed] == 'stop:event_sub_01' &&
     res1[:affordability_status] == 'affordable_with_plan'

puts "  method=#{res1[:recommended_payment_method]}, spending=#{res1[:spending_changes_needed]}, status=#{res1[:affordability_status]}"
if assert(t1, 'Flexible recurring expense is stopped, making plan affordable by deadline')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 2: Flexible recurring expense can be reduced to a lower amount
# ---------------------------------------------------------------------------
puts "\n--- [TEST 2] Flexible recurring expense can be reduced ---"
# Setup: user needs 1000 today, available balance is 1400, min_bal is 100.
# Recurring dining is 300/mo (900 over 90 days).
# Without reduction: 1400 - 1000 - 900 = -500 < 100 (unsafe).
# Reduced to 100/mo: 1400 - 1000 - 300 = 100 >= 100 (safe).
prof2 = {
  'user_id' => 'u_t2', 'home_currency' => 'USD', 'current_available_balance' => '1400',
  'minimum_balance_to_keep' => '100', 'payment_methods_user_will_consider' => 'full_payment',
  'expense_categories_to_protect' => 'rent',
  'expense_categories_user_is_willing_to_stop' => '',
  'expense_categories_user_is_willing_to_reduce' => 'dining'
}
ev_dining = {
  'event_id' => 'event_din_01', 'user_id' => 'u_t2', 'event_type' => 'expense',
  'category' => 'dining', 'direction' => 'debit', 'amount' => '300', 'currency' => 'USD',
  'event_date' => '2026-05-15', 'settlement_date' => '2026-05-15', 'status' => 'settled',
  'flexibility' => 'reducible', 'minimum_allowed_amount' => '100', 'description' => 'Dining'
}
stream2 = Recurrence::RecurringStream.new(
  name: 'Dining', category: 'dining', event_type: 'expense',
  amount: Money.parse('300'), currency: 'USD', cadence: :monthly,
  day_of_month: 15, anchor_date: Date.parse('2026-05-15'), last_event_id: 'event_din_01', is_income: false
)
fc2 = FinancialEngine.evaluate_request(req1, prof2, [ev_dining], recurring_streams_override: [stream2])
res2 = PaymentPlanner.select_plan(req1, prof2, fc2, opts1, events: [ev_dining])

t2 = res2[:recommended_payment_method] == 'full_payment' &&
     res2[:spending_changes_needed] == 'reduce_to:event_din_01:100' &&
     res2[:affordability_status] == 'affordable_with_plan'

puts "  method=#{res2[:recommended_payment_method]}, spending=#{res2[:spending_changes_needed]}, status=#{res2[:affordability_status]}"
if assert(t2, 'Flexible recurring expense is reduced to minimum_allowed_amount')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 3: Essential/fixed expenses are never proposed
# ---------------------------------------------------------------------------
puts "\n--- [TEST 3] Essential/fixed expenses are never proposed ---"
ev_rent = {
  'event_id' => 'event_rent_01', 'user_id' => 'u_t3', 'event_type' => 'expense',
  'category' => 'rent', 'direction' => 'debit', 'amount' => '1000', 'currency' => 'USD',
  'event_date' => '2026-05-01', 'settlement_date' => '2026-05-01', 'status' => 'settled',
  'flexibility' => 'fixed', 'minimum_allowed_amount' => nil, 'description' => 'Apartment Rent'
}
stream3 = Recurrence::RecurringStream.new(
  name: 'Rent', category: 'rent', event_type: 'expense',
  amount: Money.parse('1000'), currency: 'USD', cadence: :monthly,
  day_of_month: 1, anchor_date: Date.parse('2026-05-01'), last_event_id: 'event_rent_01', is_income: false
)
prof3 = {
  'user_id' => 'u_t3', 'home_currency' => 'USD', 'current_available_balance' => '500',
  'minimum_balance_to_keep' => '100', 'payment_methods_user_will_consider' => 'full_payment',
  'expense_categories_to_protect' => 'rent',
  'expense_categories_user_is_willing_to_stop' => 'rent',
  'expense_categories_user_is_willing_to_reduce' => 'rent'
}
eligible3 = SpendingChanges.find_eligible_changes(prof3, [stream3], [ev_rent])
t3 = eligible3.empty?
puts "  eligible changes for fixed/protected rent: #{eligible3.size} (expected: 0)"
if assert(t3, 'Fixed and protected expenses are never eligible for spending changes')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 4: One-off expenses are never proposed
# ---------------------------------------------------------------------------
puts "\n--- [TEST 4] One-off expenses are never proposed ---"
ev_oneoff = {
  'event_id' => 'event_oneoff_99', 'user_id' => 'u_t4', 'event_type' => 'expense',
  'category' => 'shopping', 'direction' => 'debit', 'amount' => '500', 'currency' => 'USD',
  'event_date' => '2026-04-10', 'settlement_date' => '2026-04-10', 'status' => 'settled',
  'flexibility' => 'stoppable', 'minimum_allowed_amount' => nil, 'description' => 'One-off electronics'
}
prof4 = {
  'user_id' => 'u_t4', 'home_currency' => 'USD',
  'expense_categories_to_protect' => '',
  'expense_categories_user_is_willing_to_stop' => 'shopping'
}
eligible4 = SpendingChanges.find_eligible_changes(prof4, [], [ev_oneoff])
t4 = eligible4.empty?
puts "  eligible changes for one-off event: #{eligible4.size} (expected: 0)"
if assert(t4, 'One-off transactions are never proposed for spending changes')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 5: stop and reduce_to are never emitted together for the same event
# ---------------------------------------------------------------------------
puts "\n--- [TEST 5] stop and reduce_to are mutually exclusive per event ---"
ev_dual = {
  'event_id' => 'event_dual_01', 'user_id' => 'u_t5', 'event_type' => 'subscription',
  'category' => 'streaming', 'direction' => 'debit', 'amount' => '50', 'currency' => 'USD',
  'event_date' => '2026-05-10', 'settlement_date' => '2026-05-10', 'status' => 'settled',
  'flexibility' => 'reducible_or_stoppable', 'minimum_allowed_amount' => '25', 'description' => 'Streaming'
}
stream5 = Recurrence::RecurringStream.new(
  name: 'Streaming', category: 'streaming', event_type: 'subscription',
  amount: Money.parse('50'), currency: 'USD', cadence: :monthly,
  day_of_month: 10, anchor_date: Date.parse('2026-05-10'), last_event_id: 'event_dual_01', is_income: false
)
prof5 = {
  'user_id' => 'u_t5', 'home_currency' => 'USD',
  'expense_categories_to_protect' => '',
  'expense_categories_user_is_willing_to_stop' => 'streaming',
  'expense_categories_user_is_willing_to_reduce' => 'streaming'
}
eligible5 = SpendingChanges.find_eligible_changes(prof5, [stream5], [ev_dual])
combs5 = SpendingChanges.generate_combinations(eligible5, 3)

has_dual_conflict = combs5.any? do |comb|
  eids = comb.map(&:event_id)
  eids.count('event_dual_01') > 1
end

t5 = eligible5.size == 2 && combs5.size == 2 && !has_dual_conflict
puts "  combinations generated: #{combs5.size}, has conflict: #{has_dual_conflict}"
if assert(t5, 'stop and reduce_to for the same event are never placed in the same combination')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 6: Reduction amount must be strictly lower than existing recurring amount
# ---------------------------------------------------------------------------
puts "\n--- [TEST 6] Reduction amount must be strictly lower than recurring amount ---"
ev_invalid_min = {
  'event_id' => 'event_bad_min', 'user_id' => 'u_t6', 'event_type' => 'expense',
  'category' => 'dining', 'direction' => 'debit', 'amount' => '100', 'currency' => 'USD',
  'event_date' => '2026-05-15', 'settlement_date' => '2026-05-15', 'status' => 'settled',
  'flexibility' => 'reducible', 'minimum_allowed_amount' => '100', # min >= amount
  'description' => 'Dining'
}
stream6 = Recurrence::RecurringStream.new(
  name: 'Dining', category: 'dining', event_type: 'expense',
  amount: Money.parse('100'), currency: 'USD', cadence: :monthly,
  day_of_month: 15, anchor_date: Date.parse('2026-05-15'), last_event_id: 'event_bad_min', is_income: false
)
prof6 = {
  'user_id' => 'u_t6', 'home_currency' => 'USD',
  'expense_categories_to_protect' => '',
  'expense_categories_user_is_willing_to_reduce' => 'dining'
}
eligible6 = SpendingChanges.find_eligible_changes(prof6, [stream6], [ev_invalid_min])
t6 = eligible6.empty?
puts "  eligible reductions when min_amt >= stream.amount: #{eligible6.size} (expected: 0)"
if assert(t6, 'Reductions where new_amount >= existing amount are rejected')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 7: Invalid/nonexistent event IDs cannot be emitted
# ---------------------------------------------------------------------------
puts "\n--- [TEST 7] Invalid/nonexistent event IDs cannot be emitted ---"
stream7_ghost = Recurrence::RecurringStream.new(
  name: 'Ghost', category: 'dining', event_type: 'expense',
  amount: Money.parse('100'), currency: 'USD', cadence: :monthly,
  day_of_month: 15, anchor_date: Date.parse('2026-05-15'), last_event_id: 'event_nonexistent_99999', is_income: false
)
eligible7 = SpendingChanges.find_eligible_changes(prof6, [stream7_ghost], [])
t7 = eligible7.empty?
puts "  eligible changes for unverified event ID: #{eligible7.size} (expected: 0)"
if assert(t7, 'Nonexistent event IDs are rejected — all changes require verified events')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 8: Maximum 3 spending changes is enforced
# ---------------------------------------------------------------------------
puts "\n--- [TEST 8] Maximum 3 spending changes enforced ---"
streams8 = []
events8 = []
5.times do |i|
  eid = "event_flex_#{i}"
  cat = "sub_cat_#{i}"
  events8 << {
    'event_id' => eid, 'user_id' => 'u_t8', 'event_type' => 'subscription',
    'category' => cat, 'direction' => 'debit', 'amount' => '50', 'currency' => 'USD',
    'event_date' => '2026-05-10', 'settlement_date' => '2026-05-10', 'status' => 'settled',
    'flexibility' => 'stoppable', 'minimum_allowed_amount' => nil, 'description' => cat
  }
  streams8 << Recurrence::RecurringStream.new(
    name: cat, category: cat, event_type: 'subscription',
    amount: Money.parse('50'), currency: 'USD', cadence: :monthly,
    day_of_month: 10, anchor_date: Date.parse('2026-05-10'), last_event_id: eid, is_income: false
  )
end
prof8 = {
  'user_id' => 'u_t8', 'home_currency' => 'USD',
  'expense_categories_to_protect' => '',
  'expense_categories_user_is_willing_to_stop' => (0..4).map { |i| "sub_cat_#{i}" }.join('|')
}
eligible8 = SpendingChanges.find_eligible_changes(prof8, streams8, events8)
combs8 = SpendingChanges.generate_combinations(eligible8, 3)

max_size = combs8.map(&:size).max
t8 = eligible8.size == 5 && max_size == 3 && combs8.all? { |c| c.size <= 3 }
puts "  eligible streams: #{eligible8.size}, max combination size: #{max_size} (expected: 3)"
if assert(t8, 'Combination generator strictly enforces maximum of 3 spending changes')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 9: Proposed spending change must actually make the financial plan safe
# ---------------------------------------------------------------------------
puts "\n--- [TEST 9] Proposed spending change makes plan safe ---"
t9 = res1[:recommended_payment_method] == 'full_payment' &&
     res1[:spending_changes_needed] == 'stop:event_sub_01'
if assert(t9, 'Proposed spending change achieves safe on-time payment')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 10: Spending change that still leaves minimum balance violated is rejected
# ---------------------------------------------------------------------------
puts "\n--- [TEST 10] Insufficient spending change is rejected ---"
req10 = {
  'request_id' => 'req_t10', 'user_id' => 'u_t10', 'request_date' => '2026-06-01',
  'requested_amount' => '50000', 'desired_completion_date' => '2026-06-15', 'allows_partial_payment' => 'false'
}
prof10 = {
  'user_id' => 'u_t10', 'home_currency' => 'USD', 'current_available_balance' => '1000',
  'minimum_balance_to_keep' => '100', 'payment_methods_user_will_consider' => 'full_payment',
  'expense_categories_to_protect' => '',
  'expense_categories_user_is_willing_to_stop' => 'streaming'
}
opts10 = [{
  'payment_option_id' => 'opt_fp10', 'request_id' => 'req_t10', 'payment_method' => 'full_payment',
  'payment_amount' => '50000', 'number_of_payments' => '1', 'first_payment_date' => '2026-06-01',
  'total_payable_amount' => '50000'
}]
fc10 = FinancialEngine.evaluate_request(req10, prof10, [ev_sub1], recurring_streams_override: [stream1])
res10 = PaymentPlanner.select_plan(req10, prof10, fc10, opts10, events: [ev_sub1])

t10 = res10[:recommended_payment_method] == 'not_recommended' &&
      res10[:spending_changes_needed] == 'none' &&
      res10[:affordability_status] == 'not_affordable'

puts "  method=#{res10[:recommended_payment_method]}, spending=#{res10[:spending_changes_needed]}, status=#{res10[:affordability_status]}"
if assert(t10, 'Insufficient spending change that fails safety check is rejected (spending: none)')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 11: Existing Stage 5 plans with no spending changes continue to work unchanged
# ---------------------------------------------------------------------------
puts "\n--- [TEST 11] Existing Stage 5 plans with no spending changes work unchanged ---"
r01  = samples.find { |r| r['request_id'] == 'request_01' }
p01  = profile_map[r01['user_id']]
fc01 = FinancialEngine.evaluate_request(r01, p01, events)
opts01 = pay_opts_by_req['request_01'] || []
res11 = PaymentPlanner.select_plan(r01, p01, fc01, opts01, events: events)

t11 = res11[:recommended_payment_method] == 'full_payment' &&
      res11[:payment_plan] == '2024-03-03:25256' &&
      res11[:affordability_status] == 'affordable_now' &&
      res11[:spending_changes_needed] == 'none'

puts "  method=#{res11[:recommended_payment_method]}, plan=#{res11[:payment_plan]}, spending=#{res11[:spending_changes_needed]}"
if assert(t11, 'request_01 retains full_payment, affordable_now, and spending_changes: none')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 12: Deterministic tie-breaking produces identical results on repeated runs
# ---------------------------------------------------------------------------
puts "\n--- [TEST 12] Deterministic tie-breaking on repeated runs ---"
runs = 100.times.map do
  PaymentPlanner.select_plan(req1, prof1, fc1, opts1, events: [ev_sub1])[:spending_changes_needed]
end
t12 = runs.uniq.size == 1 && runs.first == 'stop:event_sub_01'
puts "  unique results over 100 runs: #{runs.uniq.size} (#{runs.first})"
if assert(t12, '100 repeated runs produce the exact identical spending_changes_needed string')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 13: Real dataset flexible recurring expenses and sample requests verification
# ---------------------------------------------------------------------------
puts "\n--- [TEST 13] Real dataset flexible recurring expenses verification ---"
# Check real dataset users have correct eligible flexible streams:
# user_06: streaming (event_476) stoppable
u06_events = events.select { |e| e['user_id'] == 'user_06' }
p06 = profile_map['user_06']
streams06 = Recurrence.detect('user_06', Date.parse('2026-01-03'), u06_events, p06)
el06 = SpendingChanges.find_eligible_changes(p06, streams06, u06_events)
t13_u06 = el06.any? { |c| c.string == 'stop:event_476' }

# user_11: dining (event_989) reducible to 665950
u11_events = events.select { |e| e['user_id'] == 'user_11' }
p11 = profile_map['user_11']
streams11 = Recurrence.detect('user_11', Date.parse('2025-05-03'), u11_events, p11)
el11 = SpendingChanges.find_eligible_changes(p11, streams11, u11_events)
t13_u11 = el11.any? { |c| c.string == 'reduce_to:event_989:665950' }

# user_21: cloud_storage (event_1815) stoppable, streaming (event_1816) reducible to 23.50
u21_events = events.select { |e| e['user_id'] == 'user_21' }
p21 = profile_map['user_21']
streams21 = Recurrence.detect('user_21', Date.parse('2026-04-03'), u21_events, p21)
el21 = SpendingChanges.find_eligible_changes(p21, streams21, u21_events)
t13_u21 = el21.any? { |c| c.string == 'stop:event_1815' } &&
          el21.any? { |c| c.string == 'reduce_to:event_1816:23.50' }

# Real sample request_22 (installments with 3 payments, spending: none)
r22 = samples.find { |r| r['request_id'] == 'request_22' }
p22 = profile_map[r22['user_id']]
opts22 = pay_opts_by_req['request_22'] || []
fc22 = FinancialEngine.evaluate_request(r22, p22, events)
res13_22 = PaymentPlanner.select_plan(r22, p22, fc22, opts22, events: events)
t13_r22 = res13_22[:spending_changes_needed] == 'none' && res13_22[:recommended_payment_method] == 'installments'

puts "  user_06 eligible includes stop:event_476: #{t13_u06}"
puts "  user_11 eligible includes reduce_to:event_989:665950: #{t13_u11}"
puts "  user_21 eligible includes stop:event_1815 and reduce_to:event_1816:23.50: #{t13_u21}"
puts "  request_22 spending_changes_needed is none: #{t13_r22}"

t13 = t13_u06 && t13_u11 && t13_u21 && t13_r22
if assert(t13, 'Real dataset flexible recurring expenses and sample requests verified accurately')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 14: Full regression (Stages 2, 3, 4, 5, 6)
# ---------------------------------------------------------------------------
puts "\n--- [TEST 14] Full regression across all stages ---"
st2_ok = system('ruby', File.expand_path('verify_stage2.rb', __dir__), out: File::NULL, err: File::NULL)
st3_ok = system('ruby', File.expand_path('verify_stage3.rb', __dir__), out: File::NULL, err: File::NULL)
st4_ok = system('ruby', File.expand_path('verify_stage4.rb', __dir__), out: File::NULL, err: File::NULL)
st5_ok = system('ruby', File.expand_path('verify_stage5.rb', __dir__), out: File::NULL, err: File::NULL)
st6_ok = system('ruby', File.expand_path('verify_stage6.rb', __dir__), out: File::NULL, err: File::NULL)

all_regressions_ok = st2_ok && st3_ok && st4_ok && st5_ok && st6_ok
puts "  Stage 2: #{st2_ok ? 'PASS' : 'FAIL'}"
puts "  Stage 3: #{st3_ok ? 'PASS' : 'FAIL'}"
puts "  Stage 4: #{st4_ok ? 'PASS' : 'FAIL'}"
puts "  Stage 5: #{st5_ok ? 'PASS' : 'FAIL'}"
puts "  Stage 6: #{st6_ok ? 'PASS' : 'FAIL'}"

if assert(all_regressions_ok, 'All previous verification suites (Stages 2–6) pass with zero regressions')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
total = pass_count + fail_count
puts "\n=================================================="
puts "STAGE 7 RESULTS: #{pass_count}/#{total} PASSED"
puts '=================================================='

if fail_count > 0
  puts "#{fail_count} test(s) FAILED."
  exit 1
else
  puts 'ALL STAGE 7 TESTS PASSED.'
  exit 0
end
