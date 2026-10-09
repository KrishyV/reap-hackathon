require "net/http"
require "json"
require "bigdecimal"
require "bigdecimal/util"
require_relative "money"
require_relative "log"

module Shopper
  # Live currency conversion for international shopping.
  #
  # Budgets, card funding and holds are in the budget currency (USD). Merchants may
  # price in another currency. Every conversion used for *budgeting* is deliberately
  # conservative: it rounds up and adds the card's FX markup plus a drift buffer, so
  # the real charge cannot exceed what was reserved.
  class FX
    class Unavailable < StandardError; end

    # rates: { "GBP" => BigDecimal(0.757), ... } = units of that currency per 1 base unit.
    Table = Struct.new(:base, :rates, :source, :as_of, :fetched_at, keyword_init: true)

    # Live ECB reference rates from Frankfurter (MIT-licensed, keyless, self-hostable:
    # set FX_URL to your own instance). The only non-Reap/OpenAI network call.
    class HttpSource
      DEFAULT_URL = "https://api.frankfurter.dev/v1/latest?base=%<base>s"

      def initialize(url: ENV.fetch("FX_URL", DEFAULT_URL), timeout: 8)
        @url = url
        @timeout = timeout
      end

      def fetch(base)
        uri = URI(format(@url, base:))
        body = Log.time("fx.http", source: "frankfurter", host: uri.host, base:) do
          res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @timeout, read_timeout: @timeout) { |h| h.get(uri.request_uri) }
          raise "HTTP #{res.code}" unless res.code.to_i == 200
          res.body
        end
        j = JSON.parse(body)
        table = j.fetch("rates").to_h { |cur, r| [cur.upcase, BigDecimal(r.to_s)] }.reject { |_, r| r <= 0 }
        Table.new(base:, rates: table.merge(base => BigDecimal("1")), source: "frankfurter", as_of: j["date"].to_s, fetched_at: Time.now)
      rescue Unavailable
        raise
      rescue StandardError => e
        Log.warn("fx.source_failed", source: "frankfurter", base:, error_message: e.message)
        raise Unavailable, "frankfurter: #{e.message}"
      end
    end

    # ECB snapshot shipped with the app (lib/shopper/fx_snapshot.json), used when the
    # live source is unreachable. Older data, so FX adds `stale_buffer_bps` on top.
    class BundledSource
      PATH = File.join(__dir__, "fx_snapshot.json")

      def initialize(path: PATH)
        @data = JSON.parse(File.read(path))
      end

      def as_of = @data["date"]

      def fetch(base)
        usd = @data.fetch("rates").to_h { |k, v| [k.upcase, BigDecimal(v.to_s)] }.merge(@data["base"] => BigDecimal("1"))
        pivot = usd[base.upcase] or raise Unavailable, "bundled snapshot has no #{base}"
        rates = usd.transform_values { |r| r / pivot }
        Table.new(base:, rates:, source: "bundled-ecb", as_of: @data["date"], fetched_at: Time.now)
      end
    end

    # Tries each source in order.
    class ChainSource
      def initialize(*sources) = @sources = sources

      def fetch(base)
        errors = []
        @sources.each do |src|
          return src.fetch(base)
        rescue Unavailable => e
          errors << e.message
        end
        raise Unavailable, "no FX source available (#{errors.join('; ')})"
      end
    end

    # Fixed rates, for tests and offline demos.
    class StaticSource
      def initialize(rates_by_base, as_of: "static")
        @rates = rates_by_base.transform_values { |h| h.to_h { |k, v| [k.upcase, BigDecimal(v.to_s)] } }
        @as_of = as_of
      end

      def fetch(base)
        rates = @rates.fetch(base) { raise Unavailable, "no static rates for #{base}" }
        Table.new(base:, rates: rates.merge(base => BigDecimal("1")), source: "static", as_of: @as_of, fetched_at: Time.now)
      end
    end

    Conversion = Struct.new(:from, :to, :rate, :markup_bps, :buffer_bps, :source, :as_of, keyword_init: true) do
      def to_h_public = { from: from.to_s, to: to.to_s, rate: rate.round(6).to_s("F"), markup_bps:, buffer_bps:, source:, as_of: }
    end

    attr_reader :markup_bps, :buffer_bps, :stale_buffer_bps
    STALE_SOURCES = %w[bundled-ecb].freeze

    def self.offline = new(source: StaticSource.new({}), markup_bps: 0, buffer_bps: 0)

    def self.default_source = ChainSource.new(HttpSource.new, BundledSource.new)

    def initialize(source: FX.default_source, ttl: 3600, markup_bps: 150, buffer_bps: 100, stale_buffer_bps: 300,
                   clock: -> { Time.now }, cache: nil)
      raise ArgumentError, "markup_bps must be >= 0" if markup_bps.to_i.negative?
      raise ArgumentError, "buffer_bps must be >= 0" if buffer_bps.to_i.negative?
      @source = source
      @ttl = ttl
      @markup_bps = markup_bps.to_i
      @buffer_bps = buffer_bps.to_i
      @stale_buffer_bps = stale_buffer_bps.to_i
      @clock = clock
      @cache = cache || { tables: {}, mutex: Mutex.new }
    end

    # Same rates cache, different fee assumptions (e.g. the card account's real FX markup).
    def with_markup(bps) = self.class.new(source: @source, ttl: @ttl, markup_bps: bps, buffer_bps: @buffer_bps,
                                          stale_buffer_bps: @stale_buffer_bps, clock: @clock, cache: @cache)

    # Units of `to` per 1 unit of `from`.
    def rate(from:, to:)
      from = from.upcase
      to = to.upcase
      return BigDecimal("1") if from == to
      t = table(to)
      per_base = t.rates[from] or raise Unavailable, "no #{from}→#{to} rate from #{t.source}"
      BigDecimal("1") / per_base
    end

    # Upper-bound estimate used to fit baskets and size card holds.
    # Snapshot rates may be days old, so they carry an extra drift buffer.
    def estimate(money, to:) = convert(money, to:, extra_bps: @markup_bps + @buffer_bps, stale_aware: true)

    # Expected settled charge: current rate plus the card FX markup, rounded up.
    def settle(money, to:) = convert(money, to:, extra_bps: @markup_bps)

    def describe(money, to:)
      return nil if money.currency == to.upcase
      t = table(to)
      Conversion.new(from: money, to: estimate(money, to:), rate: rate(from: money.currency, to:),
                     markup_bps: @markup_bps, buffer_bps: @buffer_bps + stale_extra(t), source: t.source, as_of: t.as_of)
    end

    def snapshot
      @cache[:mutex].synchronize do
        @cache[:tables].transform_values { |t| { source: t.source, as_of: t.as_of, fetched_at: t.fetched_at.utc.iso8601, currencies: t.rates.size } }
      end
    end

    private

    def stale_extra(table) = STALE_SOURCES.include?(table.source) ? @stale_buffer_bps : 0

    def convert(money, to:, extra_bps:, stale_aware: false)
      to = to.upcase
      return money if money.currency == to
      r = rate(from: money.currency, to:)
      extra_bps += stale_extra(table(to)) if stale_aware
      exact = BigDecimal(money.cents) * r * (BigDecimal(10_000 + extra_bps) / 10_000)
      out = Money.new(exact.round(0, BigDecimal::ROUND_CEILING).to_i, to)
      Log.debug("fx.convert", from: money.to_s, to: out.to_s, rate: r.round(6).to_s("F"), extra_bps:)
      out
    end

    def table(base)
      @cache[:mutex].synchronize do
        cached = @cache[:tables][base]
        ttl = STALE_SOURCES.include?(cached&.source) ? [@ttl, 60].min : @ttl
        if cached && @clock.call - cached.fetched_at < ttl
          return cached
        end
        begin
          fresh = @source.fetch(base)
          fresh.fetched_at = @clock.call
          @cache[:tables][base] = fresh
          Log.info("fx.rates_loaded", base:, source: fresh.source, as_of: fresh.as_of, currencies: fresh.rates.size)
          fresh
        rescue Unavailable => e
          raise unless cached
          Log.warn("fx.stale_rates_used", base:, source: cached.source, age_s: (@clock.call - cached.fetched_at).round, error: e.message)
          cached
        end
      end
    end
  end
end
