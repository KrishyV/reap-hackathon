RSpec.describe Shopper::WebhookVerifier do
  let(:secret) { G.printable_ascii_string(empty: false) }
  let(:body) { G.printable_string }
  let(:now) { 1_800_000_000 }

  it "verifies what it signs" do
    forall(secret, body, G.choose(-300..300)) do |s, b, skew|
      header = described_class.sign(s, b, now + skew)
      expect(described_class.verify!(secret: s, raw_body: b, header:, now:)).to be(true)
    end
  end

  it "rejects a tampered body" do
    forall(secret, body, G.printable_ascii_char) do |s, b, extra|
      header = described_class.sign(s, b, now)
      expect { described_class.verify!(secret: s, raw_body: b + extra, header:, now:) }.to raise_error(described_class::Invalid)
    end
  end

  it "rejects a tampered signature or wrong secret" do
    forall(secret, body, G.choose(0..63)) do |s, b, pos|
      header = described_class.sign(s, b, now)
      sig = header[/v1=(\h+)/, 1]
      flipped = sig.dup.tap { _1[pos] = _1[pos] == "0" ? "1" : "0" }
      expect { described_class.verify!(secret: s, raw_body: b, header: "t=#{now},v1=#{flipped}", now:) }.to raise_error(described_class::Invalid)
      expect { described_class.verify!(secret: "#{s}x", raw_body: b, header:, now:) }.to raise_error(described_class::Invalid)
      expect { described_class.verify!(secret: s, raw_body: b, header: "t=#{now},v1=#{sig[0..-2]}", now:) }.to raise_error(described_class::Invalid)
    end
  end

  it "rejects stale or future timestamps" do
    forall(secret, body, G.choose(301..1_000_000), G.boolean) do |s, b, age, future|
      ts = future ? now + age : now - age
      header = described_class.sign(s, b, ts)
      expect { described_class.verify!(secret: s, raw_body: b, header:, now:) }.to raise_error(described_class::Invalid, /tolerance/)
    end
  end

  it "rejects arbitrary malformed headers with Invalid, never another exception" do
    forall(G.printable_ascii_string, runs: 300) do |junk|
      expect { described_class.verify!(secret: "s", raw_body: "{}", header: junk, now:) }.to raise_error(described_class::Invalid)
    end
  end

  it "rejects specific malformed headers" do
    [nil, "", "garbage", "t=abc,v1=00", "v1=00", "t=#{now}", "t=#{now},v1=", ",,", "t=#{now},,v1=ab", "=", "t"].each do |h|
      expect { described_class.verify!(secret: "s", raw_body: "{}", header: h, now:) }
        .to raise_error(described_class::Invalid), "header #{h.inspect}"
    end
  end

  it "refuses to verify without a secret" do
    expect { described_class.verify!(secret: "", raw_body: "", header: described_class.sign("", "", now), now:) }
      .to raise_error(described_class::Invalid, /secret/)
  end
end
