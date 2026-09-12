#!/usr/bin/env ruby
require_relative '../lib/unstructured_context'

result = UnstructuredContext.build
contexts = result.contexts.values

puts "== warnings (#{result.warnings.size}) =="
result.warnings.each { |w| puts "  #{w}" }
puts

with_context = contexts.select(&:has_unstructured_context)
puts "requests total:                #{contexts.size}"
puts "requests needing LLM extraction: #{with_context.size}"
puts "  - with messages only:  #{with_context.count { |c| c.message_ids.any? && c.image_ids.empty? }}"
puts "  - with images only:    #{with_context.count { |c| c.image_ids.any? && c.message_ids.empty? }}"
puts "  - with both:           #{with_context.count { |c| c.message_ids.any? && c.image_ids.any? }}"
puts "requests skipping LLM (deterministic only): #{contexts.size - with_context.size}"
puts

puts "== sample rows =="
contexts.first(6).each do |c|
  puts "#{c.request_id} (#{c.user_id}): has_unstructured_context=#{c.has_unstructured_context} " \
       "message_ids=#{c.message_ids} image_ids=#{c.image_ids}"
end
puts "..."
with_context.first(6).each do |c|
  puts "#{c.request_id} (#{c.user_id}): has_unstructured_context=#{c.has_unstructured_context} " \
       "message_ids=#{c.message_ids} image_ids=#{c.image_ids}"
end
