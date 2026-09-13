#!/usr/bin/env ruby
# frozen_string_literal: true

# Buy or Wait? — Stage 9 full pipeline entry point.
#
# Usage (from repository root):
#   ruby code/main.rb
#
# Environment (optional):
#   VISION_PROVIDER=mock|gemini|openai
#   VISION_MODEL=<model name>
#   MESSAGE_PROVIDER=mock|gemini|openai
#   MESSAGE_MODEL=<model name>
#   GEMINI_API_KEY / OPENAI_API_KEY as required by chosen providers

$LOAD_PATH.unshift File.expand_path('lib', __dir__)

require_relative 'lib/pipeline'

def main
  stats = Pipeline.run
  report_stats(stats)
rescue Pipeline::ValidationError => e
  warn "Pipeline aborted: #{e.message}"
  exit 1
rescue Pipeline::ProviderConfigError => e
  warn "Provider configuration error: #{e.message}"
  exit 2
rescue Pipeline::Error => e
  warn "Pipeline error: #{e.message}"
  exit 1
end

def report_stats(stats)
  puts 'Pipeline complete.'
  puts "  requests processed:          #{stats.requests_processed}"
  puts "  output rows:                 #{stats.output_rows}"
  puts "  requests requiring LLM:      #{stats.requests_requiring_llm}"
  puts "  deterministic-only requests: #{stats.deterministic_only_requests}"
  puts "  image extractions:           #{stats.image_extractions}"
  puts "  message extractions:         #{stats.message_extractions}"
  puts "  validation failures:         #{stats.validation_failures}"
  puts "  output:                      #{Pipeline.default_output_path}"
end

main if $PROGRAM_NAME == __FILE__
