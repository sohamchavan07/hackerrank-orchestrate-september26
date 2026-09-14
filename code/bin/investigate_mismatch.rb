#!/usr/bin/env ruby
# frozen_string_literal: true

# Investigate the key mismatches between our solution and expected outputs.

require 'csv'
require 'tempfile'
require 'fileutils'

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require_relative '../lib/dataset'
require_relative '../lib/pipeline'

# Create temp dataset
temp_dir = Dir.mktmpdir('investigate_')
FileUtils.cp_r(File.join(__dir__, '..', '..', 'dataset', '.'), temp_dir)

# Process only request_06 and request_21
sample = CSV.read(File.join(__dir__, '..', '..', 'dataset', 'sample_requests.csv'), headers: true)

%w[request_06 request_21].each do |rid|
  sample_row = sample.find { |r| r['request_id'] == rid }
  puts "=" * 80
  puts "ANALYZING #{rid}"
  puts "=" * 80
  puts "Requested amount: #{sample_row['requested_amount']}"
  puts "Desired completion: #{sample_row['desired_completion_date']}"
  puts "Expected amount_safe_to_pay: #{sample_row['amount_safe_to_pay']}"
  puts "Expected method: #{sample_row['recommended_payment_method']}"
  puts "Expected plan: #{sample_row['payment_plan']}"
  puts "Expected earliest_date: #{sample_row['earliest_date_for_full_payment']}"
  puts "Expected spending_changes: #{sample_row['spending_changes_needed']}"
  puts "Request text: #{sample_row['request_text']}"
  puts

  # Create temp requests.csv with only this request
  temp_req_file = File.join(temp_dir, 'requests.csv')
  CSV.open(temp_req_file, 'w') do |csv|\n    csv << %w[request_id user_id request_date request_type requested_amount desired_completion_date allows_partial_payment request_text]
    cols = %w[request_id user_id request_date request_type requested_amount desired_completion_date allows_partial_payment request_text]
    row = cols.map { |col| sample_row[col] || '' }
    csv << row
  end

  # Set Dataset::ROOT to temp_dir
  Dataset.send(:remove_const, :ROOT) if Dataset.const_defined?(:ROOT)
  Dataset.const_set(:ROOT, temp_dir)

  Pipeline.send(:define_method, :default_output_path) { File.join(Dataset::ROOT, 'output.csv') }

  # Run pipeline
  stats = Pipeline.run
  puts "Pipeline stats: #{stats.output_rows} rows"

  # Read output
  out_file = File.join(Dataset::ROOT, 'output.csv')
  if File.exist?(out_file)
    out = CSV.read(out_file, headers: true).first
    puts "Actual output:"
    %w[amount_safe_to_pay affordability_status recommended_payment_method payment_plan earliest_date_for_full_payment spending_changes_needed].each do |field|
      puts "  #{field}: #{out[field]}"
    end
    puts "  decision_explanation: #{out['decision_explanation']}"
  end

  puts
  puts
  end

# Cleanup
FileUtils.rm_rf(temp_dir)