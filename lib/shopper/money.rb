require "bigdecimal"

module Shopper
  # Integer-cents money value. Floats from JSON are converted exactly once, at the boundary.
  class Money
    include Comparable

    DECIMAL_PATTERN = /\A\d+(\.\d{1,2})?\z/

    attr_reader :cents, :currency

    def self.zero(currency = "USD") = new(0, currency)

    # Parse user input such as "150" or "149.99". Rejects negatives, junk and sub-cent precision.
    def self.parse(text, currency = "USD")
      str = text.to_s.strip
      raise ArgumentError, "invalid amount: #{text.inspect}" unless str.match?(DECIMAL_PATTERN)
      new((BigDecimal(str) * 100).to_i, currency)
    end

    # Reap amounts arrive as JSON numbers (e.g. 46.99) inside { amount:, currency: }.
    def self.from_api(obj)
      amount = obj.fetch("amount")
      currency = obj.fetch("currency", "USD")
      decimal = BigDecimal(amount.to_s)
      raise ArgumentError, "negative amount: #{amount}" if decimal.negative?
      new((decimal * 100).round(0, BigDecimal::ROUND_HALF_EVEN).to_i, currency)
    end

    def initialize(cents, currency = "USD")
      raise ArgumentError, "cents must be an Integer" unless cents.is_a?(Integer)
      raise ArgumentError, "amount cannot be negative" if cents.negative?
      @cents = cents
      @currency = currency.to_s.upcase.freeze
      freeze
    end

    def +(other)
      check_currency!(other)
      Money.new(cents + other.cents, currency)
    end

    def -(other)
      check_currency!(other)
      Money.new(cents - other.cents, currency)
    end

    def *(quantity)
      raise ArgumentError, "quantity must be a non-negative Integer" unless quantity.is_a?(Integer) && quantity >= 0
      Money.new(cents * quantity, currency)
    end

    def <=>(other)
      return nil unless other.is_a?(Money) && other.currency == currency
      cents <=> other.cents
    end

    def eql?(other) = other.is_a?(Money) && other.currency == currency && other.cents == cents
    alias == eql?
    def hash = [cents, currency].hash

    def zero? = cents.zero?

    # Decimal string with exactly two places, used for postings ("100.00").
    def to_decimal_string = format("%d.%02d", cents / 100, cents % 100)

    # JSON number for Reap endpoints that take numeric amounts.
    def to_api_number = BigDecimal(to_decimal_string).to_f

    def to_s = "#{currency == 'USD' ? '$' : "#{currency} "}#{to_decimal_string}"
    def inspect = "#<Money #{self}>"

    def self.sum(list, currency = "USD") = list.reduce(zero(currency)) { |acc, m| acc + m }

    private

    def check_currency!(other)
      raise ArgumentError, "expected Money" unless other.is_a?(Money)
      raise ArgumentError, "currency mismatch #{currency} vs #{other.currency}" unless other.currency == currency
    end
  end
end
