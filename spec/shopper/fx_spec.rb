RSpec.describe Shopper::FX do
  def static(rates = { "GBP" => "0.75", "EUR" => "0.9", "JPY" => "150" }) = Shopper::FX::StaticSource.new({ "USD" => rates })
  def money(cents, cur) = Shopper::Money.new(cents, cur)

  let(:fx) { described_class.new(source: static, markup_bps: 150, buffer_bps: 100) }

  it "treats same-currency conversion as the identity, with no fees" do
    forall(G.choose(0..10_000_000)) do |c|
      expect(fx.estimate(usd(c), to: "USD")).to eq(usd(c))
      expect(fx.settle(usd(c), to: "USD")).to eq(usd(c))
    end
    expect(fx.describe(usd(100), to: "USD")).to be_nil
  end

  it "never under-estimates: estimate >= settle >= exact conversion, all in the target currency" do
    rate_gen = G.choose(1..500_000).map { |n| BigDecimal(n) / 1000 } # 0.001 .. 500 units per USD
    forall(G.tuple(rate_gen, G.choose(0..5_000_000), G.choose(0..500), G.choose(0..500))) do |(r, cents, markup, buffer)|
      f = described_class.new(source: Shopper::FX::StaticSource.new({ "USD" => { "XYZ" => r } }), markup_bps: markup, buffer_bps: buffer)
      exact = BigDecimal(cents) / r
      est = f.estimate(money(cents, "XYZ"), to: "USD")
      settle = f.settle(money(cents, "XYZ"), to: "USD")
      expect(est.currency).to eq("USD")
      expect(BigDecimal(settle.cents)).to be >= exact * (1 + BigDecimal(markup) / 10_000)
      expect(est.cents).to be >= settle.cents
      # Rounds up by less than one cent beyond the fee-adjusted amount.
      expect(BigDecimal(est.cents) - exact * (1 + BigDecimal(markup + buffer) / 10_000)).to be < 1
    end
  end

  it "is monotonic in the amount" do
    forall(G.tuple(G.choose(0..1_000_000), G.choose(0..1_000_000))) do |(a, b)|
      lo, hi = [a, b].minmax
      expect(fx.estimate(money(lo, "GBP"), to: "USD")).to be <= fx.estimate(money(hi, "GBP"), to: "USD")
    end
  end

  it "applies markup and buffer exactly on a worked example" do
    # £75.00 at 0.75 GBP/USD = $100.00; +1.5% markup +1% buffer = $102.50
    expect(fx.estimate(money(7_500, "GBP"), to: "USD")).to eq(usd(10_250))
    expect(fx.settle(money(7_500, "GBP"), to: "USD")).to eq(usd(10_150))
    expect(fx.rate(from: "GBP", to: "USD").round(6)).to eq(BigDecimal("1.333333"))
    d = fx.describe(money(7_500, "GBP"), to: "USD").to_h_public
    expect(d).to include(markup_bps: 150, buffer_bps: 100, source: "static", to: "$102.50")
  end

  it "raises Unavailable for an unknown currency" do
    expect { fx.estimate(money(100, "ZZZ"), to: "USD") }.to raise_error(Shopper::FX::Unavailable)
    expect { described_class.offline.estimate(money(100, "GBP"), to: "USD") }.to raise_error(Shopper::FX::Unavailable)
  end

  it "rejects negative fees" do
    expect { described_class.new(source: static, markup_bps: -1) }.to raise_error(ArgumentError)
    expect { described_class.new(source: static, buffer_bps: -1) }.to raise_error(ArgumentError)
  end

  describe "caching" do
    let(:source) do
      Class.new do
        attr_reader :calls
        attr_accessor :fail, :gbp

        def initialize = (@calls = 0; @gbp = "0.75")

        def fetch(base)
          @calls += 1
          raise Shopper::FX::Unavailable, "down" if fail
          Shopper::FX::Table.new(base:, rates: { "GBP" => BigDecimal(gbp), base => BigDecimal(1) }, source: "fake", as_of: "d", fetched_at: Time.now)
        end
      end.new
    end
    let(:now) { [Time.at(1_000_000)] }
    let(:cached_fx) { described_class.new(source:, ttl: 3600, clock: -> { now[0] }) }

    it "reuses rates within the TTL and refreshes after it" do
      cached_fx.rate(from: "GBP", to: "USD")
      now[0] += 3599
      cached_fx.rate(from: "GBP", to: "USD")
      expect(source.calls).to eq(1)
      now[0] += 2
      source.gbp = "0.5"
      expect(cached_fx.rate(from: "GBP", to: "USD")).to eq(2)
      expect(source.calls).to eq(2)
    end

    it "falls back to stale rates when the refresh fails, and logs it" do
      cached_fx.rate(from: "GBP", to: "USD")
      now[0] += 7200
      source.fail = true
      expect(cached_fx.rate(from: "GBP", to: "USD").round(4)).to eq(BigDecimal("1.3333"))
      expect(Shopper::Log.recent(event: "fx.stale_rates_used")).not_to be_empty
    end

    it "raises when there is nothing cached and the source is down" do
      source.fail = true
      expect { cached_fx.rate(from: "GBP", to: "USD") }.to raise_error(Shopper::FX::Unavailable)
    end

    it "shares the cache across with_markup copies" do
      cached_fx.rate(from: "GBP", to: "USD")
      other = cached_fx.with_markup(300)
      other.rate(from: "GBP", to: "USD")
      expect(source.calls).to eq(1)
      expect(other.markup_bps).to eq(300)
    end
  end

  describe Shopper::FX::HttpSource do
    let(:url) { "https://api.frankfurter.dev/v1/latest?base=USD" }

    it "parses Frankfurter rates" do
      stub_request(:get, url).to_return(status: 200, body: { base: "USD", date: "2026-10-08", rates: { GBP: 0.75, EUR: 0.9 } }.to_json)
      t = described_class.new.fetch("USD")
      expect(t.rates).to include("GBP" => BigDecimal("0.75"), "USD" => BigDecimal(1))
      expect([t.source, t.as_of]).to eq(%w[frankfurter 2026-10-08])
    end

    it "raises Unavailable on HTTP errors, timeouts and junk" do
      stub_request(:get, url).to_return(status: 500).then.to_timeout.then.to_return(status: 200, body: "nope")
      3.times { expect { described_class.new.fetch("USD") }.to raise_error(Shopper::FX::Unavailable) }
    end

    it "supports a self-hosted Frankfurter via a URL template" do
      stub_request(:get, "http://fx.local/latest?base=SGD").to_return(status: 200, body: { date: "d", rates: { USD: 0.77 } }.to_json)
      expect(described_class.new(url: "http://fx.local/latest?base=%<base>s").fetch("SGD").rates["USD"]).to eq(BigDecimal("0.77"))
    end
  end

  describe "bundled snapshot fallback" do
    it "converts from the shipped ECB snapshot, re-based on request" do
      t = Shopper::FX::BundledSource.new.fetch("USD")
      expect(t.source).to eq("bundled-ecb")
      expect(t.rates["GBP"]).to be_between(BigDecimal("0.3"), BigDecimal("2"))
      eur = Shopper::FX::BundledSource.new.fetch("EUR")
      expect(eur.rates["EUR"]).to eq(1)
    end

    it "is used when the live source is down, with an extra drift buffer on estimates" do
      stub_request(:get, %r{frankfurter}).to_return(status: 503)
      f = described_class.new(markup_bps: 150, buffer_bps: 100, stale_buffer_bps: 300)
      gbp = Shopper::Money.new(10_000, "GBP")
      live_like = described_class.new(source: Shopper::FX::BundledSource.new, markup_bps: 150, buffer_bps: 400, stale_buffer_bps: 0)
      expect(f.estimate(gbp, to: "USD")).to eq(live_like.estimate(gbp, to: "USD"))
      expect(f.describe(gbp, to: "USD").buffer_bps).to eq(400)
    end
  end
end
