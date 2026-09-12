require 'csv'

# Thin loading layer over dataset/*.csv. Deliberately dumb: returns arrays of
# plain Hash rows with string keys, blank strings normalized to nil. Typed
# parsing (BigDecimal amounts, Date fields) happens in the stage that needs
# it, not here, so this file has zero opinions about the financial engine.
module Dataset
  ROOT = File.expand_path('../../dataset', __dir__)

  FILES = {
    requests: 'requests.csv',
    sample_requests: 'sample_requests.csv',
    financial_profiles: 'financial_profiles.csv',
    financial_events: 'financial_events.csv',
    exchange_rates: 'exchange_rates.csv',
    request_payment_options: 'request_payment_options.csv',
    messages: 'messages.csv',
    images: 'images.csv'
  }.freeze

  # Dataset.load(:messages) => [{ "message_id" => "message_01", "user_id" => "user_02", ... }, ...]
  def self.load(name)
    path = File.join(ROOT, FILES.fetch(name) { raise ArgumentError, "unknown dataset #{name}" })
    CSV.read(path, headers: true, encoding: 'UTF-8').map do |row|
      row.to_h.transform_values { |v| v.nil? || v.strip.empty? ? nil : v }
    end
  end

  def self.load_all
    FILES.keys.each_with_object({}) { |name, memo| memo[name] = load(name) }
  end
end
