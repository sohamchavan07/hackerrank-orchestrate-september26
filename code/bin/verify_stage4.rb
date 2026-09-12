#!/usr/bin/env ruby
# frozen_string_literal: true

# verify_stage4.rb — Stage 4 Deterministic Verification Script
#
# Validates:
#   1. Existing request_01 behavior remains correct (safe, earliest, status)
#   2. Stage 1 tests still pass (UnstructuredContext)
#   3. Stage 2 tests still pass (Recurrence, salary continuation, sporadic expense filter)
#   4. Stage 3 tests still pass (Image amount extraction, BigDecimal, prompt injection safety)
#   5. Full requested amount safely payable immediately (affordable_now)
#   6. Requested amount greater than safe capacity (capped at safe capacity)
#   7. Exact minimum-balance boundary (balance == min_bal -> safe = 0; balance - safe == min_bal)
#   8. Payment just above minimum-balance capacity (safeguard protects min_bal)
#   9. Future income makes full request affordable later (affordable_later)
#  10. Full request never becomes safe within forecast horizon (not_affordable)
#  11. Desired completion / deadline handling (missed deadline -> not_affordable; partial -> affordable_with_plan)
#  12. Deterministic repeated execution
#  13. No Float usage in monetary arithmetic
#  14. No Date.today / Time.now / current-time dependence
#  15. amount_safe_to_pay is calculated before optional spending changes

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require_relative '../lib/dataset'
require_relative '../lib/money'
require_relative '../lib/exchange_rates'
require_relative '../lib/recurrence'
require_relative '../lib/financial_engine'
require_relative '../lib/image_amount_extractor'
require_relative '../lib/unstructured_context'

puts '=================================================='
puts 'STAGE 4 AFFORDABILITY EVALUATION VERIFICATION'
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

# Shared datasets
requests = Dataset.load(:requests)
samples = Dataset.load(:sample_requests)
profiles = Dataset.load(:financial_profiles)
events = Dataset.load(:financial_events)
images = Dataset.load(:images)

profile_map = profiles.each_with_object({}) { |p, h| h[p['user_id']] = p }
mock_provider = ImageAmountExtractor::MockVisionProvider.new
extraction_cache = ImageAmountExtractor.build_cache(events, images, provider: mock_provider)

# ---------------------------------------------------------------------------
# TEST 1: Existing request_01 behavior remains correct
# ---------------------------------------------------------------------------
puts "\n--- [TEST 1] Existing request_01 behavior remains correct ---"
r1 = samples.find { |r| r['request_id'] == 'request_01' }
p1 = profile_map[r1['user_id']]
res1 = FinancialEngine.evaluate_request(r1, p1, events, extraction_cache: extraction_cache)

t1_safe = (res1.amount_safe_to_pay == Money.parse(r1['amount_safe_to_pay']))
t1_date = (res1.earliest_date_for_full_payment.to_s == r1['earliest_date_for_full_payment'])
t1_stat = (res1.affordability_status == r1['affordability_status'])

puts "  safe: #{res1.amount_safe_to_pay} (exp #{r1['amount_safe_to_pay']}) [#{t1_safe}]"
puts "  earliest: #{res1.earliest_date_for_full_payment} (exp #{r1['earliest_date_for_full_payment']}) [#{t1_date}]"
puts "  status: #{res1.affordability_status} (exp #{r1['affordability_status']}) [#{t1_stat}]"

if assert(t1_safe && t1_date && t1_stat, 'request_01 retains exact safe amount, earliest date, and affordable_now status')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 2: Stage 1 tests still pass
# ---------------------------------------------------------------------------
puts "\n--- [TEST 2] Stage 1 tests still pass ---"
stage1_result = UnstructuredContext.build
contexts = stage1_result.contexts.values
with_context = contexts.select(&:has_unstructured_context)
msg_only = with_context.count { |c| c.message_ids.any? && c.image_ids.empty? }
img_only = with_context.count { |c| c.image_ids.any? && c.message_ids.empty? }
both = with_context.count { |c| c.message_ids.any? && c.image_ids.any? }
det_only = contexts.size - with_context.size

t2_ok = (contexts.size == 250 && with_context.size == 200 && msg_only == 189 &&
         img_only == 2 && both == 9 && det_only == 50 && stage1_result.warnings.empty?)

if assert(t2_ok, 'Stage 1 UnstructuredContext resolution counts are 100% intact')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 3: Stage 2 tests still pass
# ---------------------------------------------------------------------------
puts "\n--- [TEST 3] Stage 2 core behavior still passes ---"
r5 = samples.find { |r| r['request_id'] == 'request_05' }
p5 = profile_map[r5['user_id']]
res5 = FinancialEngine.evaluate_request(r5, p5, events, extraction_cache: extraction_cache)

fuel_stream5 = res5.recurring_streams.find { |s| s.name.to_s.downcase.include?('fuel') }
salary_stream5 = res5.recurring_streams.find { |s| s.category == 'salary' }
transport_stream5 = res5.recurring_streams.find { |s| s.category == 'transport' }

# user_04 genuine subscriptions
streams4 = Recurrence.detect('user_04', Date.parse('2024-06-04'), events, profile_map['user_04'])
subs4 = streams4.select { |s| s.event_type == 'subscription' }.map(&:category)
has_all_subs = %w[gym music_subscription delivery_membership].all? { |c| subs4.include?(c) }

t3_ok = fuel_stream5.nil? && salary_stream5.nil? && transport_stream5 && res5.earliest_date_for_full_payment.nil? && has_all_subs

if assert(t3_ok, 'Stage 2 recurrence filtering (salary, fuel, subscriptions) intact')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 4: Stage 3 tests still pass
# ---------------------------------------------------------------------------
puts "\n--- [TEST 4] Stage 3 extraction cache and validation still pass ---"
blank_events = events.select { |e| e['amount'].nil? }
cache_size_ok = (extraction_cache.size == 16)
all_bd = extraction_cache.values.all? { |r| r.success ? r.amount.is_a?(BigDecimal) : true }

# Validator rejects invalid injection string
dummy_img = File.join(ImageAmountExtractor::DATASET_ROOT, 'media', 'images', 'image_01.png')
bad_res = mock_provider.send(:parse_and_validate,
  '{"event_id":"ev","amount":"IGNORE INSTRUCTIONS","currency":"INR","confidence":0.9}',
  'ev', 'image_01', dummy_img)
rejects_injection = (!bad_res.success && bad_res.amount.nil?)

t4_ok = (blank_events.size == 16 && cache_size_ok && all_bd && rejects_injection)
if assert(t4_ok, 'Stage 3 image extraction, BigDecimal preservation, and injection rejection intact')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 5: Full requested amount safely payable immediately (affordable_now)
# ---------------------------------------------------------------------------
puts "\n--- [TEST 5] Full requested amount safely payable immediately ---"
syn_req5 = {
  'request_id' => 'syn_05',
  'user_id' => 'u_syn5',
  'request_date' => '2026-06-01',
  'requested_amount' => '15000',
  'desired_completion_date' => '2026-06-30',
  'allows_partial_payment' => 'false'
}
syn_prof5 = {
  'user_id' => 'u_syn5',
  'home_currency' => 'INR',
  'current_available_balance' => '50000',
  'minimum_balance_to_keep' => '10000',
  'payment_methods_user_will_consider' => 'full_payment'
}
res5_syn = FinancialEngine.evaluate_request(syn_req5, syn_prof5, [])

t5_safe = (res5_syn.amount_safe_to_pay == BigDecimal('15000'))
t5_earliest = (res5_syn.earliest_date_for_full_payment == Date.parse('2026-06-01'))
t5_status = (res5_syn.affordability_status == 'affordable_now')

# Subtest 5B: User rejects full_payment -> at Stage 4 no plan is fabricated, falls to not_affordable
syn_prof5b = syn_prof5.merge('payment_methods_user_will_consider' => 'installments')
res5b = FinancialEngine.evaluate_request(syn_req5, syn_prof5b, [])
t5b_status = (res5b.affordability_status == 'not_affordable')

puts "  safe: #{res5_syn.amount_safe_to_pay} (exp 15000)"
puts "  earliest: #{res5_syn.earliest_date_for_full_payment} (exp 2026-06-01)"
puts "  status (considers full): #{res5_syn.affordability_status} (exp affordable_now)"
puts "  status (rejects full, no plan in Stage 4): #{res5b.affordability_status} (exp not_affordable)"

if assert(t5_safe && t5_earliest && t5_status && t5b_status, 'Full payment safe yields affordable_now if user accepts, and does not fabricate plan if user rejects')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 6: Requested amount greater than safe capacity
# ---------------------------------------------------------------------------
puts "\n--- [TEST 6] Requested amount greater than safe capacity ---"
syn_req6 = syn_req5.merge('requested_amount' => '60000')
# Balance is 50000, min_bal is 10000 => capacity is 40000 (< requested 60000)
res6_syn = FinancialEngine.evaluate_request(syn_req6, syn_prof5, [])

t6_safe = (res6_syn.amount_safe_to_pay == BigDecimal('40000'))
t6_less = (res6_syn.amount_safe_to_pay < BigDecimal('60000'))
t6_status = (res6_syn.affordability_status == 'not_affordable') # without future income or plans

puts "  safe: #{res6_syn.amount_safe_to_pay} (exp 40000, capped at capacity)"
puts "  status: #{res6_syn.affordability_status} (exp not_affordable)"

if assert(t6_safe && t6_less && t6_status, 'amount_safe_to_pay capped at available capacity (40000) when requested > capacity')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 7: Exact minimum-balance boundary
# ---------------------------------------------------------------------------
puts "\n--- [TEST 7] Exact minimum-balance boundary ---"
# Subtest 7A: Starting balance exactly equals minimum balance
syn_prof7a = {
  'user_id' => 'u_syn7a',
  'home_currency' => 'INR',
  'current_available_balance' => '20000',
  'minimum_balance_to_keep' => '20000',
  'payment_methods_user_will_consider' => 'full_payment'
}
syn_req7a = {
  'request_id' => 'syn_07a',
  'user_id' => 'u_syn7a',
  'request_date' => '2026-06-01',
  'requested_amount' => '5000',
  'desired_completion_date' => '2026-06-30',
  'allows_partial_payment' => 'false'
}
res7a = FinancialEngine.evaluate_request(syn_req7a, syn_prof7a, [])

# Subtest 7B: Payment leaves balance exactly at minimum balance
syn_prof7b = syn_prof7a.merge('current_available_balance' => '25000')
res7b = FinancialEngine.evaluate_request(syn_req7a, syn_prof7b, [])
rem_bal = BigDecimal('25000') - res7b.amount_safe_to_pay

t7a_ok = (res7a.amount_safe_to_pay == Money::ZERO)
t7b_ok = (res7b.amount_safe_to_pay == BigDecimal('5000') && rem_bal == BigDecimal('20000'))

puts "  Subtest 7A (balance == min): safe=#{res7a.amount_safe_to_pay} (exp 0)"
puts "  Subtest 7B (balance - safe == min): safe=#{res7b.amount_safe_to_pay} rem=#{rem_bal} (exp min=20000)"

if assert(t7a_ok && t7b_ok, 'Boundary handling exact when balance == min_bal and when payment leaves balance == min_bal')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 8: Payment just above minimum-balance capacity
# ---------------------------------------------------------------------------
puts "\n--- [TEST 8] Payment just above minimum-balance capacity ---"
# Safe capacity is 5000 (balance 25000, min 20000). Requesting 5001 (1 unit above capacity)
syn_req8 = syn_req7a.merge('requested_amount' => '5001')
res8 = FinancialEngine.evaluate_request(syn_req8, syn_prof7b, [])

t8_safe = (res8.amount_safe_to_pay == BigDecimal('5000'))
t8_protected = (BigDecimal('25000') - res8.amount_safe_to_pay >= BigDecimal('20000'))

puts "  safe: #{res8.amount_safe_to_pay} (exp 5000, 1 unit below requested 5001)"
puts "  remaining balance >= min_bal: #{t8_protected}"

if assert(t8_safe && t8_protected, 'Payment just above safe capacity (5001 vs 5000) does not breach minimum balance')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 9: Future income makes the full request affordable later
# ---------------------------------------------------------------------------
puts "\n--- [TEST 9] Future income makes full request affordable later ---"
syn_req9 = {
  'request_id' => 'syn_09',
  'user_id' => 'u_syn9',
  'request_date' => '2026-06-01',
  'requested_amount' => '20000',
  'desired_completion_date' => '2026-06-25',
  'allows_partial_payment' => 'false'
}
syn_prof9 = {
  'user_id' => 'u_syn9',
  'home_currency' => 'INR',
  'current_available_balance' => '15000',
  'minimum_balance_to_keep' => '10000',
  'payment_methods_user_will_consider' => 'full_payment'
}
# Future confirmed salary on 2026-06-15
ev_inc9 = [
  {
    'event_id' => 'ev_inc9',
    'user_id' => 'u_syn9',
    'event_date' => '2026-06-15',
    'status' => 'scheduled',
    'event_type' => 'income',
    'direction' => 'credit',
    'amount' => '25000',
    'currency' => 'INR',
    'category' => 'bonus'
  }
]
res9 = FinancialEngine.evaluate_request(syn_req9, syn_prof9, ev_inc9)

t9_safe = (res9.amount_safe_to_pay == BigDecimal('5000'))
t9_earliest = (res9.earliest_date_for_full_payment == Date.parse('2026-06-15'))
t9_status = (res9.affordability_status == 'affordable_later')

# Subtest 9B: User does NOT consider full_payment (e.g. only considers installments).
# Specification rule: earliest_date and affordable_later measure capacity independently of payment preference.
syn_prof9b = syn_prof9.merge('payment_methods_user_will_consider' => 'installments')
res9b = FinancialEngine.evaluate_request(syn_req9, syn_prof9b, ev_inc9)
t9b_status = (res9b.affordability_status == 'affordable_later')
t9b_earliest = (res9b.earliest_date_for_full_payment == Date.parse('2026-06-15'))

puts "  safe today: #{res9.amount_safe_to_pay} (exp 5000)"
puts "  earliest: #{res9.earliest_date_for_full_payment} (exp 2026-06-15)"
puts "  status (considers full): #{res9.affordability_status} (exp affordable_later)"
puts "  status (rejects full):   #{res9b.affordability_status} (exp affordable_later, independent of preference)"

t9_all = t9_safe && t9_earliest && t9_status && t9b_status && t9b_earliest
if assert(t9_all, 'Confirmed future income makes request affordable_later independently of payment preference')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 10: Full request never becomes safe within the forecast horizon
# ---------------------------------------------------------------------------
puts "\n--- [TEST 10] Full request never becomes safe within forecast horizon ---"
syn_req10 = syn_req9.merge('requested_amount' => '500000') # far exceeds 15000 balance + 25000 income
res10 = FinancialEngine.evaluate_request(syn_req10, syn_prof9, ev_inc9)

t10_earliest = res10.earliest_date_for_full_payment.nil?
t10_status = (res10.affordability_status == 'not_affordable')

puts "  earliest: #{res10.earliest_date_for_full_payment.inspect} (exp nil)"
puts "  status: #{res10.affordability_status} (exp not_affordable)"

if assert(t10_earliest && t10_status, 'Huge requested amount never safe yields earliest_date=nil and not_affordable')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 11: Desired completion / deadline handling
# ---------------------------------------------------------------------------
puts "\n--- [TEST 11] Desired completion / deadline handling ---"
# Subtest 11A: Full payment becomes safe on 2026-06-20, but desired completion is 2026-06-15 (missed deadline)
syn_req11a = {
  'request_id' => 'syn_11a',
  'user_id' => 'u_syn11',
  'request_date' => '2026-06-01',
  'requested_amount' => '20000',
  'desired_completion_date' => '2026-06-15',
  'allows_partial_payment' => 'false'
}
syn_prof11 = {
  'user_id' => 'u_syn11',
  'home_currency' => 'INR',
  'current_available_balance' => '15000',
  'minimum_balance_to_keep' => '10000',
  'payment_methods_user_will_consider' => 'full_payment'
}
ev_late11 = [
  {
    'event_id' => 'ev_late11',
    'user_id' => 'u_syn11',
    'event_date' => '2026-06-20',
    'status' => 'scheduled',
    'event_type' => 'income',
    'direction' => 'credit',
    'amount' => '25000',
    'currency' => 'INR',
    'category' => 'bonus'
  }
]
res11a = FinancialEngine.evaluate_request(syn_req11a, syn_prof11, ev_late11)

# Subtest 11B: Partial payment satisfies deadline
syn_req11b = syn_req11a.merge(
  'allows_partial_payment' => 'true',
  'desired_completion_date' => '2026-06-25'
)
syn_prof11b = syn_prof11.merge('payment_methods_user_will_consider' => 'partial_payment')
res11b = FinancialEngine.evaluate_request(syn_req11b, syn_prof11b, ev_late11)

t11a_ok = (res11a.earliest_date_for_full_payment == Date.parse('2026-06-20') &&
           res11a.affordability_status == 'not_affordable')
t11b_ok = (res11b.amount_safe_to_pay == BigDecimal('5000') &&
           res11b.affordability_status == 'affordable_with_plan')

puts "  Subtest 11A (earliest > desired): earliest=#{res11a.earliest_date_for_full_payment} desired=2026-06-15 status=#{res11a.affordability_status} (exp not_affordable)"
puts "  Subtest 11B (partial payment): safe=#{res11b.amount_safe_to_pay} status=#{res11b.affordability_status} (exp affordable_with_plan)"

if assert(t11a_ok && t11b_ok, 'Missed deadline yields not_affordable for full payment; partial payment yields affordable_with_plan')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 12: Deterministic repeated execution
# ---------------------------------------------------------------------------
puts "\n--- [TEST 12] Deterministic repeated execution ---"
run1 = FinancialEngine.evaluate_request(r1, p1, events, extraction_cache: extraction_cache)
run2 = FinancialEngine.evaluate_request(r1, p1, events, extraction_cache: extraction_cache)

t12_ok = (run1.amount_safe_to_pay == run2.amount_safe_to_pay &&
          run1.earliest_date_for_full_payment == run2.earliest_date_for_full_payment &&
          run1.affordability_status == run2.affordability_status &&
          run1.daily_balances == run2.daily_balances)

if assert(t12_ok, 'Two consecutive runs on same input produce 100% identical ForecastResult')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 13: No Float usage in financial arithmetic
# ---------------------------------------------------------------------------
puts "\n--- [TEST 13] No Float usage in financial engine code ---"
engine_code = File.read(File.expand_path('../lib/financial_engine.rb', __dir__))
has_float_class = engine_code.match?(/\bFloat\b/)
has_to_f = engine_code.match?(/\.to_f\b/)

t13_ok = !has_float_class && !has_to_f
if assert(t13_ok, 'Zero Float or .to_f usage detected in financial_engine.rb')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 14: No Date.today / Time.now / current-time dependence
# ---------------------------------------------------------------------------
puts "\n--- [TEST 14] No Date.today / Time.now / current-time dependence ---"
has_today = engine_code.match?(/\bDate\.today\b/)
has_now = engine_code.match?(/\bTime\.now\b|\bDateTime\.now\b/)

t14_ok = !has_today && !has_now
if assert(t14_ok, 'Zero Date.today or Time.now usage detected in financial_engine.rb')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# TEST 15: amount_safe_to_pay calculated before optional spending changes
# ---------------------------------------------------------------------------
puts "\n--- [TEST 15] amount_safe_to_pay calculated before optional spending changes ---"
# In request_06, sample has spending changes needed (stop:event_476).
# amount_safe_to_pay before spending changes is 603.3 (< requested 620.4).
r6 = samples.find { |r| r['request_id'] == 'request_06' }
p6 = profile_map[r6['user_id']]
res6 = FinancialEngine.evaluate_request(r6, p6, events, extraction_cache: extraction_cache)

# Verify amount_safe_to_pay is evaluated on base expenses without assuming stops/reductions
t15_ok = (res6.amount_safe_to_pay < Money.parse(r6['requested_amount'])) &&
         (res6.amount_safe_to_pay > Money::ZERO)

puts "  r6 requested: #{r6['requested_amount']}"
puts "  r6 safe before spending changes: #{res6.amount_safe_to_pay} (< requested)"

if assert(t15_ok, 'amount_safe_to_pay is evaluated strictly before optional spending changes')
  pass_count += 1
else
  fail_count += 1
end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
total = pass_count + fail_count
puts "\n=================================================="
puts "STAGE 4 RESULTS: #{pass_count}/#{total} PASSED"
puts '=================================================='

if fail_count > 0
  puts "#{fail_count} test(s) FAILED."
  exit 1
else
  puts 'ALL STAGE 4 TESTS PASSED.'
  exit 0
end
