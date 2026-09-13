require 'bigdecimal'
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

  # amount is in `from_currency`; converts to `to_currency` using the fixed
  # rate dated on or before `on_date` (the event's settlement_date, per spec).
  # Uses the latest available rate row on or before that date for the stated
  # direction. Raises if no applicable rate exists.
  def self.convert(amount, from_currency, to_currency, on_date)
    return amount if from_currency == to_currency

    rate = rate_for(from_currency, to_currency, on_date)
    date_str = on_date.strftime('%Y-%m-%d')
    raise "no exchange rate for #{from_currency}->#{to_currency} on or before #{date_str}" unless rate

    Money.round(amount * rate)
  end

  # Returns the multiplier for from_currency -> to_currency on or before on_date.
  def self.rate_for(from_currency, to_currency, on_date)
    date_str = on_date.strftime('%Y-%m-%d')

    direct = latest_rate_on_or_before(from_currency, to_currency, date_str)
    return direct if direct

    inverse = latest_rate_on_or_before(to_currency, from_currency, date_str)
    return (BigDecimal('1') / inverse) if inverse

    via_usd = cross_via_usd(from_currency, to_currency, date_str)
    return via_usd if via_usd

    nil
  end

  def self.latest_rate_on_or_before(from_currency, to_currency, date_str)
    best_date = nil
    best_rate = nil

    table.each do |(rate_date, from_curr, to_curr), rate|
      next unless from_curr == from_currency && to_curr == to_currency
      next unless rate_date <= date_str

      if best_date.nil? || rate_date > best_date
        best_date = rate_date
        best_rate = rate
      end
    end

    best_rate
  end
  private_class_method :latest_rate_on_or_before

  def self.cross_via_usd(from_currency, to_currency, date_str)
    return nil if from_currency == 'USD' || to_currency == 'USD'

    to_usd = latest_rate_on_or_before(from_currency, 'USD', date_str)
    from_usd = latest_rate_on_or_before('USD', to_currency, date_str)
    return nil unless to_usd && from_usd

    to_usd * from_usd
  end
  private_class_method :cross_via_usd
end
