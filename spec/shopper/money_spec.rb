RSpec.describe Shopper::Money do
  let(:cents_gen) { G.choose(0..10_000_000_00) }

  it "round-trips through to_decimal_string and parse" do
    forall(cents_gen) do |cents|
      m = usd(cents)
      expect(m.to_decimal_string).to match(/\A\d+\.\d{2}\z/)
      expect(described_class.parse(m.to_decimal_string)).to eq(m)
    end
  end

  it "parses 0-2 decimal place inputs exactly" do
    forall(G.choose(0..1_000_000), G.choose(0..99), G.choose(0..2)) do |dollars, frac, places|
      text = case places
             when 0 then dollars.to_s
             when 1 then "#{dollars}.#{frac / 10}"
             else format("%d.%02d", dollars, frac)
             end
      expected = dollars * 100 + (places.zero? ? 0 : places == 1 ? (frac / 10) * 10 : frac)
      expect(described_class.parse(text).cents).to eq(expected)
    end
  end

  it "has commutative and associative addition" do
    forall(cents_gen, cents_gen, cents_gen) do |a, b, c|
      x, y, z = usd(a), usd(b), usd(c)
      expect(x + y).to eq(y + x)
      expect((x + y) + z).to eq(x + (y + z))
      expect((x + y).cents).to eq(a + b)
    end
  end

  it "keeps Money.sum independent of order" do
    forall(G.array(cents_gen, max: 10)) do |list|
      expect(described_class.sum(list.map { usd(_1) })).to eq(described_class.sum(list.shuffle.map { usd(_1) }))
      expect(described_class.sum(list.map { usd(_1) }).cents).to eq(list.sum)
    end
  end

  describe ".from_api" do
    it "reads JSON floats without float drift" do
      forall(cents_gen) do |cents|
        float = cents / 100.0
        expect(described_class.from_api({ "amount" => float, "currency" => "USD" }).cents).to eq(cents)
        parsed = JSON.parse(JSON.generate({ "amount" => float }))
        expect(described_class.from_api(parsed).cents).to eq(cents)
      end
    end

    it "reads decimal strings exactly" do
      forall(cents_gen) do |cents|
        expect(described_class.from_api({ "amount" => usd(cents).to_decimal_string }).cents).to eq(cents)
      end
    end

    it "absorbs binary float noise such as 0.1 + 0.2" do
      expect(described_class.from_api({ "amount" => 0.1 + 0.2 }).cents).to eq(30)
      expect(described_class.from_api({ "amount" => 1.15 * 3 }).cents).to eq(345)
    end

    it "rejects negative amounts" do
      forall(G.choose(1..10_000_000)) do |cents|
        expect { described_class.from_api({ "amount" => -cents / 100.0 }) }.to raise_error(ArgumentError)
        expect { described_class.from_api({ "amount" => "-#{usd(cents).to_decimal_string}" }) }.to raise_error(ArgumentError)
      end
    end

    it "defaults currency to USD and upcases it" do
      expect(described_class.from_api({ "amount" => 1 }).currency).to eq("USD")
      expect(described_class.from_api({ "amount" => 1, "currency" => "eur" }).currency).to eq("EUR")
    end
  end

  describe ".parse rejection" do
    it "rejects more than two decimal places" do
      forall(G.choose(0..100_000), G.choose(3..6), G.choose(0..999_999)) do |dollars, places, frac|
        text = "#{dollars}.#{frac.to_s.rjust(places, '0')[0, places]}"
        expect { described_class.parse(text) }.to raise_error(ArgumentError)
      end
    end

    it "rejects negatives and junk" do
      ["-1", "-0.01", "1e3", "abc", "", "1.", ".5", "1,000", "$5", "1.2.3", nil].each do |bad|
        expect { described_class.parse(bad) }.to raise_error(ArgumentError), "accepted #{bad.inspect}"
      end
    end
  end

  describe "currency safety" do
    it "refuses to mix currencies" do
      forall(cents_gen, cents_gen) do |a, b|
        expect { usd(a) + described_class.new(b, "EUR") }.to raise_error(ArgumentError, /currency/)
        expect { described_class.new(a + b, "USD") - described_class.new(b, "EUR") }.to raise_error(ArgumentError, /currency/)
        expect { usd(a) < described_class.new(b, "EUR") }.to raise_error(ArgumentError)
        expect(usd(a)).not_to eq(described_class.new(a, "EUR"))
      end
    end

    it "never goes negative" do
      forall(cents_gen, G.choose(1..1000)) do |a, extra|
        expect { usd(a) - usd(a + extra) }.to raise_error(ArgumentError)
      end
    end
  end
end
