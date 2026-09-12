#!/usr/bin/env ruby
require_relative '../lib/dataset'
require_relative '../lib/money'
require_relative '../lib/exchange_rates'
require_relative '../lib/recurrence'
require_relative '../lib/financial_engine'
require_relative '../lib/unstructured_context'

puts '=================================================='
puts 'STAGE 2 DETERMINISTIC ENGINE VERIFICATION'
puts '=================================================='

requests = Dataset.load(:requests)
samples = Dataset.load(:sample_requests)
profiles = Dataset.load(:financial_profiles)
events = Dataset.load(:financial_events)

profile_map = profiles.each_with_object({}) { |p, h| h[p['user_id']] = p }

# --- TEST 1: request_01 SALARY CONTINUATION (BUG 1) ---
puts "\n--- [TEST 1] request_01: Salary Continuation (Bug 1) ---"
r1 = samples.find { |r| r['request_id'] == 'request_01' }
p1 = profile_map[r1['user_id']]
res1 = FinancialEngine.evaluate_request(r1, p1, events)

puts "User: #{r1['user_id']} | Requested: #{r1['requested_amount']} | Min Bal: #{p1['minimum_balance_to_keep']}"
puts "Expected amount_safe_to_pay: #{r1['amount_safe_to_pay']}"
puts "Actual amount_safe_to_pay:   #{res1.amount_safe_to_pay}"
puts "Expected earliest_date:      #{r1['earliest_date_for_full_payment']}"
puts "Actual earliest_date:        #{res1.earliest_date_for_full_payment}"

salary_stream1 = res1.recurring_streams.find { |s| s.category == 'salary' }
puts "Salary stream detected:      #{salary_stream1 ? "#{salary_stream1.name}, amt=#{salary_stream1.amount} #{salary_stream1.currency}, day=#{salary_stream1.day_of_month}" : 'NONE'}"

if res1.amount_safe_to_pay == Money.parse(r1['amount_safe_to_pay']) &&
   res1.earliest_date_for_full_payment.to_s == r1['earliest_date_for_full_payment'] &&
   salary_stream1 && salary_stream1.amount == BigDecimal('23320')
  puts '>> PASS: request_01 correctly continues confirmed scheduled salary!'
else
  puts '>> FAIL: request_01 failed salary continuation check.'
  exit 1
end

# --- TEST 2: request_05 SPORADIC FUEL EXPENSE (BUG 2) ---
puts "\n--- [TEST 2] request_05: Sporadic Fuel Not Recurring (Bug 2) ---"
r5 = samples.find { |r| r['request_id'] == 'request_05' }
p5 = profile_map[r5['user_id']]
res5 = FinancialEngine.evaluate_request(r5, p5, events)

# Check user_05 streams
fuel_stream5 = res5.recurring_streams.find { |s| s.name.to_s.downcase.include?('fuel') }
salary_stream5 = res5.recurring_streams.find { |s| s.category == 'salary' }
transport_stream5 = res5.recurring_streams.find { |s| s.category == 'transport' }

puts "Fuel stream detected:        #{fuel_stream5 ? 'YES (BUG!)' : 'NONE (CORRECT)'}"
puts "Salary stream detected:      #{salary_stream5 ? 'YES (BUG!)' : 'NONE (CORRECT - employment ended)'}"
puts "Transport stream detected:   #{transport_stream5 ? "#{transport_stream5.name}, cadence=#{transport_stream5.interval_days} days" : 'NONE'}"
puts "Earliest date for full pay:  #{res5.earliest_date_for_full_payment.inspect} (Expected: nil)"

if fuel_stream5.nil? && salary_stream5.nil? && transport_stream5 && res5.earliest_date_for_full_payment.nil?
  puts '>> PASS: request_05 rejects sporadic 2-occurrence fuel expense and ended salary!'
else
  puts '>> FAIL: request_05 recurrence filtering failed.'
  exit 1
end

# --- TEST 3: GENUINE SUBSCRIPTIONS PRESERVATION ---
puts "\n--- [TEST 3] Genuine Subscriptions Preservation ---"
u4_events = events.select { |e| e['user_id'] == 'user_04' }
p4 = profile_map['user_04']
streams4 = Recurrence.detect('user_04', Date.parse('2024-06-04'), events, p4)
subs4 = streams4.select { |s| s.event_type == 'subscription' }
puts "user_04 subscriptions found: #{subs4.map(&:category).inspect}"

expected_subs = %w[gym music_subscription delivery_membership]
if expected_subs.all? { |c| subs4.any? { |s| s.category == c } }
  puts '>> PASS: All genuine user_04 subscriptions preserved!'
else
  puts ">> FAIL: Missing subscriptions in user_04. Found: #{subs4.map(&:category)}"
  exit 1
end

# --- TEST 4: GENUINE SALARY RECURRENCE PRESERVATION ---
puts "\n--- [TEST 4] Genuine Salary Series Preservation ---"
sample_map = samples.each_with_object({}) { |s, h| h[s['user_id']] = s }
%w[user_02 user_03 user_04].each do |uid|
  p = profile_map[uid]
  req_date = Date.parse(sample_map[uid]['request_date'])
  streams = Recurrence.detect(uid, req_date, events, p)
  sal = streams.find { |s| s.category == 'salary' }
  puts "  #{uid} (req_date: #{req_date}): salary stream = #{sal ? "#{sal.amount} #{sal.currency} on day #{sal.day_of_month}" : 'NONE'}"
  if sal.nil?
    puts ">> FAIL: Expected ongoing salary for #{uid}"
    exit 1
  end
end
puts '>> PASS: Ongoing monthly salaries correctly preserved!'

# --- TEST 5: GENUINE RECURRING EXPENSES PRESERVATION ---
puts "\n--- [TEST 5] Genuine Recurring Expenses Preservation ---"
streams1 = res1.recurring_streams
has_rent1 = streams1.any? { |s| s.category == 'rent' && s.amount == BigDecimal('5148') }
has_debt1 = streams1.any? { |s| s.category == 'debt_repayment' && s.amount == BigDecimal('3487') }
has_groc1 = streams1.any? { |s| s.category == 'groceries' }
has_trans1 = streams1.any? { |s| s.category == 'transport' }

if has_rent1 && has_debt1 && has_groc1 && has_trans1
  puts '>> PASS: Rent (5148), Debt (3487), Groceries, and Transport preserved for user_01!'
else
  puts '>> FAIL: Missing recurring expenses for user_01'
  exit 1
end

# --- TEST 6: STAGE 1 BEHAVIOR PRESERVATION ---
puts "\n--- [TEST 6] Stage 1 Verification ---"
stage1_result = UnstructuredContext.build
contexts = stage1_result.contexts.values
with_context = contexts.select(&:has_unstructured_context)
msg_only = with_context.count { |c| c.message_ids.any? && c.image_ids.empty? }
img_only = with_context.count { |c| c.image_ids.any? && c.message_ids.empty? }
both = with_context.count { |c| c.message_ids.any? && c.image_ids.any? }
det_only = contexts.size - with_context.size
warnings_count = stage1_result.warnings.size

puts "Requests total:     #{contexts.size} (Expected: 250)"
puts "With context total: #{with_context.size} (Expected: 200)"
puts "  - messages only:  #{msg_only} (Expected: 189)"
puts "  - images only:    #{img_only} (Expected: 2)"
puts "  - both:           #{both} (Expected: 9)"
puts "Deterministic only: #{det_only} (Expected: 50)"
puts "Warnings:           #{warnings_count} (Expected: 0)"

if contexts.size == 250 && with_context.size == 200 && msg_only == 189 &&
   img_only == 2 && both == 9 && det_only == 50 && warnings_count == 0
  puts '>> PASS: Stage 1 behavior is 100% identical and intact!'
else
  puts '>> FAIL: Stage 1 behavior changed!'
  exit 1
end

# --- TEST 7: CODE INTEGRITY CHECKS (NO FLOAT, NO DATE.TODAY) ---
puts "\n--- [TEST 7] Code Integrity Checks (No Float, No Date.today) ---"
stage2_files = %w[
  code/lib/recurrence.rb
  code/lib/financial_engine.rb
]

float_violations = []
today_violations = []

stage2_files.each do |fpath|
  path = File.expand_path("../../#{fpath}", __dir__)
  content = File.read(path)
  float_violations << fpath if content.match?(/\bFloat\b|\.to_f\b/)
  today_violations << fpath if content.match?(/Date\.today\b|Time\.now\b/)
end

if float_violations.empty? && today_violations.empty?
  puts '>> PASS: Zero Float or Date.today usage found in Stage 2 code!'
else
  puts ">> FAIL: Violations found: Float: #{float_violations}, Date.today: #{today_violations}"
  exit 1
end

# --- TEST 8: DETERMINISM CHECK ---
puts "\n--- [TEST 8] Determinism Check ---"
res1_again = FinancialEngine.evaluate_request(r1, p1, events)
res5_again = FinancialEngine.evaluate_request(r5, p5, events)

if res1.amount_safe_to_pay == res1_again.amount_safe_to_pay &&
   res1.earliest_date_for_full_payment == res1_again.earliest_date_for_full_payment &&
   res5.amount_safe_to_pay == res5_again.amount_safe_to_pay &&
   res5.earliest_date_for_full_payment == res5_again.earliest_date_for_full_payment
  puts '>> PASS: Forecast engine is 100% deterministic across multiple runs!'
else
  puts '>> FAIL: Forecast engine produced non-deterministic results!'
  exit 1
end

puts "\n=================================================="
puts 'ALL STAGE 2 TESTS PASSED SUCCESSFULLY!'
puts '=================================================='
