require 'bigdecimal'

module Money
  ZERO = BigDecimal('0')

  def self.parse(str)
    BigDecimal(str.to_s)
  end

  # Single rounding point for the whole system: round-half-up to 2dp.
  # Applied at currency conversion and nowhere else, so it never compounds.
  def self.round(amount, decimals = 2)
    amount.round(decimals, BigDecimal::ROUND_HALF_UP)
  end
end
