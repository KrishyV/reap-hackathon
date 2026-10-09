RSpec.describe Shopper::Reap::Idempotency do
  # A small alphabet including the separator and escape characters maximises collisions.
  let(:part) { G.array(G.one_of(*%w[a b | \\ x].map { G.constant(_1) }), max: 4).map(&:join) }
  let(:parts) { list_of(part, 1, 4) }

  it "is deterministic and 64 lowercase hex characters" do
    forall(parts) do |ps|
      key = described_class.key(*ps)
      expect(key).to match(/\A[0-9a-f]{64}\z/)
      expect(described_class.key(*ps.map(&:dup))).to eq(key)
    end
  end

  it "gives distinct keys to distinct part lists" do
    forall(parts, parts, runs: 500) do |a, b|
      next if a == b
      expect(described_class.key(*a)).not_to eq(described_class.key(*b)), "collision: #{a.inspect} vs #{b.inspect}"
    end
  end

  it "separates embedded separators from separate parts" do
    expect(described_class.key("a|b")).not_to eq(described_class.key("a", "b"))
    expect(described_class.key("a|", "b")).not_to eq(described_class.key("a", "|b"))
    expect(described_class.key("a\\", "b")).not_to eq(described_class.key("a", "\\b"))
    expect(described_class.key("run1", "Acme", "hold")).not_to eq(described_class.key("run1", "Acme", "capture"))
  end

  it "requires at least one part" do
    expect { described_class.key }.to raise_error(ArgumentError)
  end
end
