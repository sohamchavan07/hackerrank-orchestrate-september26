# frozen_string_literal: true

require 'csv'
require 'json'
require 'sinatra/base'

require_relative '../code/lib/dataset'
require_relative '../code/lib/pipeline'

class BuyOrWaitAPI < Sinatra::Base
  set :root, File.expand_path('..', __dir__)
  set :bind, '0.0.0.0'
  set :port, ENV.fetch('PORT', 3000)

  before do
    content_type :json
  end

  get '/' do
    {
      service: 'buy-or-wait-api',
      status: 'ok',
      message: 'Buy or Wait? API wrapper',
      endpoints: [
        '/api/v1/health',
        '/api/v1/dashboard',
        '/api/v1/forecast',
        '/api/v1/commitments',
        'POST /api/v1/affordability/check'
      ]
    }.to_json
  end

  get '/api/v1/health' do
    {
      status: 'ok',
      service: 'buy-or-wait-api',
      repo_root: settings.root
    }.to_json
  end

  get '/api/v1/dashboard' do
    requests = Dataset.load(:requests)
    profiles = Dataset.load(:financial_profiles)
    events = Dataset.load(:financial_events)
    output_rows = read_output_rows

    {
      status: 'ok',
      request_count: requests.size,
      profile_count: profiles.size,
      event_count: events.size,
      output_rows: output_rows.size,
      needs_generation: output_rows.empty?
    }.to_json
  end

  get '/api/v1/forecast' do
    stats = run_pipeline

    {
      ok: true,
      requests_processed: stats.requests_processed,
      output_rows: stats.output_rows,
      validation_failures: stats.validation_failures,
      output_path: output_path
    }.to_json
  end

  get '/api/v1/commitments' do
    events = Dataset.load(:financial_events)
    profiles = Dataset.load(:financial_profiles)

    commitments = events
      .select do |event|
        category = (event['category'] || '').downcase
        event_type = (event['event_type'] || '').downcase
        category.match?(/rent|mortgage|insurance|utility|subscription|credit|loan|debt|transport|telecom|housing/i) ||
          event_type.match?(/rent|mortgage|insurance|utility|subscription|credit|loan|debt|transport|telecom|housing/i)
      end
      .first(25)
      .map do |event|
        {
          event_id: event['event_id'],
          user_id: event['user_id'],
          category: event['category'],
          event_type: event['event_type'],
          amount: event['amount'],
          date: event['date'],
          status: event['status'],
          description: event['description']
        }
      end

    {
      user_count: profiles.size,
      commitments: commitments
    }.to_json
  end

  post '/api/v1/affordability/check' do
    payload = JSON.parse(request.body.read)
    request_id = payload['request_id'] || payload['requestId']

    if request_id.to_s.strip.empty?
      status 400
      { ok: false, error: 'request_id is required' }.to_json
    else
      decision = fetch_decision_for(request_id)
      if decision.nil?
        status 404
        { ok: false, error: "No decision found for request_id=#{request_id}" }.to_json
      else
        { ok: true, request_id: request_id, decision: decision }.to_json
      end
    end
  rescue JSON::ParserError
    status 400
    { ok: false, error: 'Request body must be valid JSON' }.to_json
  end

  private

  def output_path
    File.join(settings.root, 'output.csv')
  end

  def read_output_rows
    return [] unless File.exist?(output_path)

    CSV.read(output_path, headers: true, encoding: 'UTF-8')
  rescue StandardError
    []
  end

  def run_pipeline
    Pipeline.run(output_path: output_path)
  end

  def fetch_decision_for(request_id)
    run_pipeline if !File.exist?(output_path) || CSV.read(output_path, headers: true).empty?
    rows = read_output_rows
    row = rows.find { |entry| entry['request_id'].to_s == request_id.to_s }
    row&.to_h&.transform_keys(&:to_s)
  rescue StandardError
    nil
  end
end
