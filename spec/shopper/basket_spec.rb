RSpec.describe Shopper::Basket do
  MERCHANTS = %w[Acme Bolt Cove].freeze

  # [[priority, quantity, [[price_cents, merchant_idx], ...]], ...], budget_percent
  def scenario_gen
    option = G.tuple(G.choose(1..20_000), G.choose(0..2))
    item = G.tuple(G.choose(1..3), G.choose(1..5), list_of(option, 1, 3))
    G.tuple(list_of(item, 1, 8), G.choose(0..130), G.choose(0..500))
  end

  def build(raw_items, pct, jitter)
    items = raw_items.each_with_index.map do |(priority, qty, opts), i|
      options = opts.each_with_index.map do |(cents, m), j|
        Fakes.option(merchant: MERCHANTS[m], cents:, id: "i#{i}o#{j}")
      end
      Shopper::Item.new(key: "k#{i}", name: "Need #{i}", priority:, quantity: qty, options:, why: "")
    end
    preferred = items.sum { |it| it.options.first.unit_price.cents * it.quantity }
    [items, usd(preferred * pct / 100 + jitter)]
  end

  def cheapest_total(items) = items.sum { |it| it.options.map { _1.unit_price.cents }.min * it.quantity }
  def preferred_total(items) = items.sum { |it| it.options.first.unit_price.cents * it.quantity }

  def check_fit(runs: 300)
    forall(scenario_gen, runs:) do |(raw, pct, jitter)|
      items, budget = build(raw, pct, jitter)
      yield items, budget, described_class.fit(items, budget)
    end
  end

  it "never exceeds the budget" do
    check_fit do |_items, budget, result|
      expect(result.total).to be <= budget
      expect(result.remaining.cents).to be >= 0
      expect(result.total.cents).to eq(result.picks.sum { |p| p.option.unit_price.cents * p.item.quantity })
    end
  end

  it "accounts for every item exactly once across picks and drops" do
    check_fit do |items, _budget, result|
      seen = result.picks.map(&:item) + result.drops.map(&:item)
      expect(seen.map(&:key).sort).to eq(items.map(&:key).sort)
      expect(seen.size).to eq(items.size)
    end
  end

  it "drops nothing when the cheapest options fit" do
    check_fit do |items, budget, result|
      next unless cheapest_total(items) <= budget.cents
      expect(result.drops).to be_empty
    end
  end

  it "keeps every first-choice option when the preferred basket fits" do
    check_fit do |items, budget, result|
      next unless preferred_total(items) <= budget.cents
      expect(result.drops).to be_empty
      result.picks.each { |p| expect(p.option).to equal(p.item.options.first) }
    end
  end

  it "only ever chooses an option belonging to the picked item" do
    check_fit do |_items, _budget, result|
      result.picks.each { |p| expect(p.item.options).to include(p.option) }
    end
  end

  it "never leaves an item dropped for budget that would still fit at its cheapest option" do
    check_fit do |_items, _budget, result|
      result.drops.select { _1.reason == :over_budget }.each do |d|
        cheapest = d.item.options.map { _1.unit_price.cents }.min * d.item.quantity
        expect(cheapest).to be > result.remaining.cents,
                            "dropped '#{d.item.name}' (#{cheapest}c) with #{result.remaining.cents}c left"
      end
    end
  end

  it "is deterministic" do
    check_fit(runs: 100) do |items, budget, result|
      again = described_class.fit(items, budget)
      expect(again.picks.map { [_1.item.key, _1.option.product_id] }).to eq(result.picks.map { [_1.item.key, _1.option.product_id] })
    end
  end

  it "uses spare budget on a cheap extra when an essential cannot be afforded" do
    a = Shopper::Item.new(key: "a", name: "A", priority: 1, quantity: 1, options: [Fakes.option(merchant: "Acme", cents: 500)])
    b = Shopper::Item.new(key: "b", name: "B", priority: 3, quantity: 1, options: [Fakes.option(merchant: "Acme", cents: 100)])
    result = described_class.fit([a, b], usd(300))
    expect(result.picks.map { _1.item.key }).to eq(["b"])
    expect(result.drops.map { _1.item.key }).to eq(["a"])
  end

  describe "examples" do
    let(:essential) do
      Shopper::Item.new(key: "e", name: "Essential", priority: 1, quantity: 1,
                        options: [Fakes.option(merchant: "Acme", cents: 6000), Fakes.option(merchant: "Acme", cents: 4000)])
    end
    let(:nice) do
      Shopper::Item.new(key: "n", name: "Nice", priority: 3, quantity: 2,
                        options: [Fakes.option(merchant: "Bolt", cents: 2000), Fakes.option(merchant: "Bolt", cents: 1000)])
    end

    it "downgrades the least important item before anything else" do
      result = described_class.fit([essential, nice], usd(8000))
      expect(result.picks.map { [_1.item.key, _1.option.unit_price.cents] }).to eq([["e", 6000], ["n", 1000]])
      expect(result.drops).to be_empty
    end

    it "drops the least important item and upgrades the rest when it is still over budget" do
      nice.quantity = 3 # cheapest basket is now 4000 + 3000 = 7000
      result = described_class.fit([essential, nice], usd(6500))
      expect(result.picks.map { [_1.item.key, _1.option.unit_price.cents] }).to eq([["e", 6000]])
      expect(result.drops.map { [_1.item.key, _1.reason] }).to eq([["n", :over_budget]])
    end

    it "drops items with no options or zero quantity as unavailable" do
      empty = Shopper::Item.new(key: "x", name: "X", priority: 1, quantity: 1, options: [])
      zero = Shopper::Item.new(key: "z", name: "Z", priority: 1, quantity: 0, options: essential.options)
      result = described_class.fit([empty, zero, nice], usd(10_000))
      expect(result.drops.map(&:reason)).to eq(%i[no_available_option no_available_option])
      expect(result.picks.map { _1.item.key }).to eq(["n"])
    end

    it "groups picks by merchant" do
      result = described_class.fit([essential, nice], usd(100_000))
      expect(result.by_merchant.keys).to contain_exactly("Acme", "Bolt")
    end
  end
end
