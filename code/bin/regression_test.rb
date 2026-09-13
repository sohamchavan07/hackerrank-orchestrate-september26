#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression test: run 25 solved examples and compare against expected output.
# Tracks mismatches across all fields and reports detailed failures.

require 'csv'
require 'tempfile'
require 'fileutils'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'dataset'
require 'pipeline'

# Expected output columns
EXPECTED_OUTPUT_COLS = %w[
  amount_safe_to_pay
  affordability_status
  recommended_payment_method
  payment_plan
  earliest_date_for_full_payment
  spending_changes_needed
  decision_explanation
].freeze

INPUT_COLS = %w[
  request_id
  user_id
  request_date
  request_type
  requested_amount
  desired_completion_date
  allows_partial_payment
  request_text
].freeze

INPUT_CSV_COLS = %w[
  request_id
  user_id
  request_date
  request_type
  requested_amount
  desired_completion_date
  allows_partial_payment
  request_text
].freeze

# Step 1: Create a temp dataset directory
temp_dir = Dir.mktmpdir('regression_')
FileUtils.cp_r(File.join(__dir__, '..', '..', 'dataset', '.'), temp_dir)

# Step 2: Create requests.csv from sample_requests.csv (input columns only)
sample_rows = CSV.read(File.join(__dir__, '..', '..', 'dataset', 'sample_requests.csv'), headers: true)
input_rows = sample_rows.map { |row| row.to_h.slice(*INPUT_CSV_COLS) }

CSV.open(File.join(temp_dir, 'requests.csv'), 'w') do |csv|
  csv << INPUT_COLS
  input_rows.each do |row|
    csv << INPUT_COLS.map { |col| row[col] || '' }
  end
end

# Step 3: Redirect Dataset::ROOT and Pipeline default output to temp_dir
Object.send(:remove_const, :Dataset) if defined?(Dataset)
require_relative '../lib/dataset'
Dataset.send(:remove_const, :ROOT) if Dataset.const_defined?(:ROOT)
Dataset.const_set(:ROOT, temp_dir)

Pipeline.send(:define_method, :default_output_path) { File.join(Dataset::ROOT, 'output.csv') }

# Step 4: Run the pipeline
puts "=" * 80
puts "REGRESSION TEST: 25 Solved Examples"
puts "=" * 80
puts "Temp dataset: #{temp_dir}"
puts

stats = Pipeline.run
puts "Pipeline processed #{stats.output_rows} rows."
puts

# Step 5: Read generated output
generated = CSV.read(File.join(temp_dir, 'output.csv'), headers: true).map(&:to_h)
generated_by_id = generated.each_with_object({}) { |r, h| h[r['request_id']] = r }

# Step 6: Compare against expected (from original sample_requests.csv)
mismatches = []
passed = 0
failed = 0

sample_rows.each do |expected_row|
  req_id = expected_row['request_id']
  gen = generated_by_id[req_id]

  unless gen
    mismatches << {
      request_id: req_id,
      field: 'ALL',
      expected: '(missing from output)',
      actual: 'MISSING'
    }
    failed += 1
    next
  end

  EXPECTED_OUTPUT_COLS.each do |field|
    expected_val = expected_row[field].to_s.strip
    actual_val = gen[field].to_s.strip

    # Normalize: for amounts, compare numerically
    if field == 'amount_safe_to_pay'
      begin
        exp_bd = BigDecimal(expected_val)
        act_bd = BigDecimal(actual_val)
        match = exp_bd == act_bd
      rescue
        match = (expected_val == actual_val)
      end
    else
      match = (expected_val == actual_val)
    end

    if match
      passed += 1
    else
      failed += 1
      mismatches << {
        request_id: req_id,
        field: field,
        expected: expected_val,
        actual: actual_val
      }
    end
  end
end

# Step 7: Report
puts "RESULTS:"
puts "  Total field comparisons: #{passed + failed}"
puts "  Passed: #{passed}"
puts "  Failed: #{failed}"
puts

if mismatches.empty?
  puts "ALL 25 SAMPLES PASSED!"
else
  puts "MISMATCHES FOUND:"
  puts "-" * 80

  mismatches.each do |m|
    puts "Request: #{m[:request_id]} | Field: #{m[:field]}"
    puts "  Expected: #{m[:expected]}"
    puts "  Actual:   #{m[:actual]}"
    puts
  end

  # Group mismatches by request_id for investigation
  puts
  puts "MISMATCHES BY REQUEST:"
  puts "-" * 80
  mismatches.group_by { |m| m[:request_id] }.each do |req_id, req_mismatches|
    puts "Request: #{req_id} (#{req_mismatches.size} field mismatches)"
    req_mismatches.each do |m|
      puts "  #{m[:field]}: expected=#{m[:expected]} actual=#{m[:actual]}"
    end
    puts
  end
end

# Cleanup
FileUtils.rm_rf(temp_dir)

puts
puts "DONE."
exit(failed > 0 ? 1 : 0)
