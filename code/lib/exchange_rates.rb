require_relative 'dataset'
require_relative 'money'

module ExchangeRates
  def self.table
    @table ||= begin
      t = {}
      Dataset.load(:exchange_rates).each do |row|
        t[[row['rate_date'], row['from_currency'], row['to_currency']]] = Money.parse(row['rate'])
      end
      t
    end
  end

  # amount is in `from_currency`; converts to `to_currency` using the rate
  # dated `on_date` (the event's settlement_date, per spec). Raises rather
  # than guessing a nearby date if no exact rate row exists -- silently
  # approximating a financial conversion is worse than failing loudly.
  def self.convert(amount, from_currency, to_currency, on_date)
    return amount if from_currency == to_currency

    key = [on_date.strftime('%Y-%m-%d'), from_currency, to_currency]
    rate = table[key]
    raise "no exchange rate for #{from_currency}->#{to_currency} on #{key[0]}" unless rate

    Money.round(amount * rate)
  end
end
