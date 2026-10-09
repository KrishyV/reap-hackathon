RSpec.describe Shopper::Executor do
  MERCHANT_NAMES = %w[Acme Bolt Cove].freeze
  FAILURES = %i[quote shipping hold checkout poll capture release].freeze
  PROPAGATING = %i[quote shipping hold].freeze

  let(:holder) { { first_name: "Ada", last_name: "Lovelace", email: "ada@example.com" } }
  let(:address) { { firstName: "Ada", lastName: "Lovelace", addressLine1: "1 Main St", city: "SF", postalCode: "94105", country: "US" } }

  def scenario_gen
    G.fixed_hash(
      surcharge_cents: G.frequency(3 => G.constant(0), 2 => G.choose(1..3_000)),
      decline: G.frequency(5 => G.constant(false), 1 => G.constant(true)),
      status: G.frequency(2 => G.constant("COMPLETED"), 1 => G.one_of(G.constant("FAILED"), G.constant("EXPIRED"))),
      polls: G.choose(0..2),
      final_delta_cents: G.one_of(G.nil, G.choose(-500..500)),
      failure: G.frequency(10 => G.nil, 4 => G.one_of(*FAILURES.map { G.constant(_1) }))
    ).map { Fakes::Scenario.new(**_1) }
  end

  def world_gen
    option = G.tuple(G.choose(100..8_000), G.choose(0..2))
    item = G.tuple(G.choose(1..3), G.choose(1..3), list_of(option, 1, 2))
    G.tuple(list_of(item, 1, 6), G.choose(20..140), list_of(scenario_gen, 3, 3))
  end

  def build_world(raw_items, pct, scenarios)
    items = raw_items.each_with_index.map do |(priority, qty, opts), i|
      options = opts.each_with_index.map { |(c, m), j| Fakes.option(merchant: MERCHANT_NAMES[m], cents: c, id: "i#{i}o#{j}") }
      Shopper::Item.new(key: "k#{i}", name: "Need #{i}", priority:, quantity: qty, options:, why: "")
    end
    preferred = items.sum { |it| it.options.first.unit_price.cents * it.quantity }
    basket = Shopper::Basket.fit(items, usd([preferred * pct / 100, 100].max))
    by_merchant = MERCHANT_NAMES.zip(scenarios).to_h
    ledger = Fakes::Ledger.new
    cards = Fakes::Cards.new(ledger:, scenarios: by_merchant)
    agentic = Fakes::Agentic.new(ledger:, scenarios: by_merchant, prices: Fakes.prices_for(items))
    [basket, cards, agentic, ledger, by_merchant]
  end

  def executor(cards, agentic, clock: nil)
    t = 0
    described_class.new(cards:, agentic:, sleeper: ->(_) {}, clock: clock || -> { Time.at(t += 1) })
  end

  def execute(basket, cards, agentic, **kw)
    executor(cards, agentic, **kw).run(run_id: "run1", basket:, holder:, address:, enrollment_id: "enr_1",
                                       return_url: "https://example.com/return")
  end

  it "upholds every payment invariant under random quotes, declines, statuses and failures" do
    forall(world_gen, runs: 400) do |(raw, pct, scenarios)|
      basket, cards, agentic, ledger, by_merchant = build_world(raw, pct, scenarios)
      next if basket.picks.empty?

      receipt = error = nil
      begin
        receipt = execute(basket, cards, agentic)
      rescue Fakes::InjectedFailure => e
        error = e
      end
      events = ledger.events
      budget = basket.budget

      # The only exceptions that escape are ones injected before any money was held for that merchant.
      if error
        failing = by_merchant.select { |_, s| PROPAGATING.include?(s.failure) }.keys
        expect(failing).not_to be_empty
      end

      # Checkout is never created without a successful hold first.
      events.each_with_index.select { |e, _| e[:type] == :checkout }.each do |co, idx|
        expect(events[0...idx].any? { |e| e[:type] == :hold && e[:merchant] == co[:merchant] }).to be(true),
                                                                                                "checkout for #{co[:merchant]} without hold"
      end

      # Every hold is captured or released exactly once.
      holds = ledger.of(:hold)
      holds.each do |h|
        resolutions = events.select { |e| %i[capture release].include?(e[:type]) && e[:tx] == h[:tx] }
        expect(resolutions.size).to eq(1), "hold #{h[:tx]} resolved #{resolutions.size} times"
        expect(resolutions.first[:amount]).to be <= h[:amount]
      end
      expect(events.select { |e| %i[capture release].include?(e[:type]) }.map { _1[:tx] }).to all(satisfy { |tx| holds.any? { _1[:tx] == tx } })

      # Money on the card (captured + outstanding holds) never exceeds the budget at any point.
      outstanding = {}
      captured = Shopper::Money.zero
      events.each do |e|
        case e[:type]
        when :hold then outstanding[e[:tx]] = e[:amount]
        when :capture then outstanding.delete(e[:tx]); captured += e[:amount]
        when :release then outstanding.delete(e[:tx])
        end
        expect(captured + Shopper::Money.sum(outstanding.values)).to be <= budget
      end
      expect(captured).to be <= budget

      # Each hold is for exactly the merchant's latest quote.
      holds.each do |h|
        last_quote = ledger.of(:quote).select { _1[:merchant] == h[:merchant] }.last
        expect(h[:amount]).to eq(last_quote[:total])
      end

      # The card is always frozen, last, even when an exception propagates.
      expect(cards.frozen_ids).to eq([cards.card.id])
      expect(events.last[:type]).to eq(:freeze)

      next unless receipt
      expect(receipt.frozen).to be(true)
      expect(receipt.spent).to eq(captured)
      expect(receipt.spent).to be <= budget
      completed = receipt.orders.select { _1.status == "COMPLETED" }
      expect(Shopper::Money.sum(completed.map(&:final_amount))).to eq(captured)
      expect(receipt.orders.map(&:merchant)).to match_array(basket.by_merchant.keys)
    end
  end

  describe "examples" do
    let(:items) do
      [Shopper::Item.new(key: "a", name: "Tent", priority: 1, quantity: 1, options: [Fakes.option(merchant: "Acme", cents: 5_000)]),
       Shopper::Item.new(key: "b", name: "Lamp", priority: 3, quantity: 1, options: [Fakes.option(merchant: "Acme", cents: 2_000)])]
    end
    let(:basket) { Shopper::Basket.fit(items, usd(8_000)) }
    let(:ledger) { Fakes::Ledger.new }

    def world(scenario)
      scenarios = Hash.new(scenario)
      [Fakes::Cards.new(ledger:, scenarios:), Fakes::Agentic.new(ledger:, scenarios:, prices: Fakes.prices_for(items))]
    end

    it "places a happy-path order, charges the quote and freezes the card" do
      cards, agentic = world(Fakes::Scenario.happy)
      receipt = execute(basket, cards, agentic)
      expect(receipt.spent).to eq(usd(7_000))
      expect(receipt.orders.map(&:status)).to eq(["COMPLETED"])
      expect(receipt.frozen).to be(true)
      expect(ledger.events.map { _1[:type] }).to eq(%i[provision quote hold checkout capture freeze])
      expect(ledger.of(:provision).first[:max_orders]).to eq(1)
    end

    it "drops the least important item when shipping pushes the quote over budget" do
      cards, agentic = world(Fakes::Scenario.happy.tap { _1.surcharge_cents = 1_500 })
      receipt = execute(basket, cards, agentic)
      order = receipt.orders.first
      expect(order.dropped.map { _1.item.name }).to eq(["Lamp"])
      expect(order.picks.map { _1.item.name }).to eq(["Tent"])
      expect(receipt.spent).to eq(usd(6_500))
      expect(ledger.of(:quote).map { _1[:items].size }).to eq([2, 1])
    end

    it "skips the merchant when nothing fits" do
      cards, agentic = world(Fakes::Scenario.happy.tap { _1.surcharge_cents = 5_000 })
      receipt = execute(basket, cards, agentic)
      expect(receipt.orders.first.status).to eq("SKIPPED")
      expect(ledger.of(:hold)).to be_empty
      expect(receipt.spent).to eq(Shopper::Money.zero)
    end

    it "never checks out after a declined hold" do
      cards, agentic = world(Fakes::Scenario.happy.tap { _1.decline = true })
      receipt = execute(basket, cards, agentic)
      expect(receipt.orders.first.status).to eq("DECLINED")
      expect(receipt.orders.first.error).to eq("INSUFFICIENT_FUNDS")
      expect(ledger.of(:checkout)).to be_empty
    end

    it "clamps a final amount above the quote and records an anomaly" do
      cards, agentic = world(Fakes::Scenario.happy.tap { _1.final_delta_cents = 250 })
      receipt = execute(basket, cards, agentic)
      expect(receipt.spent).to eq(usd(7_000))
      expect(receipt.anomalies.join).to match(/exceeded quote/)
    end

    it "charges a lower final amount when the merchant settles for less" do
      cards, agentic = world(Fakes::Scenario.happy.tap { _1.final_delta_cents = -300 })
      expect(execute(basket, cards, agentic).spent).to eq(usd(6_700))
    end

    it "waits through approval and releases the hold on timeout" do
      cards, agentic = world(Fakes::Scenario.happy.tap { _1.polls = 1_000 })
      t = 0
      receipt = execute(basket, cards, agentic, clock: -> { Time.at(t += 100) })
      expect(receipt.orders.first.status).to eq("FAILED")
      expect(receipt.orders.first.error).to match(/Timed out/)
      expect(receipt.orders.first.approval_url).to start_with("https://approve.example/")
      expect(ledger.of(:release).size).to eq(1)
      expect(receipt.spent).to eq(Shopper::Money.zero)
    end

    it "records an anomaly and reports frozen: false when freezing fails" do
      cards, agentic = world(Fakes::Scenario.happy)
      cards.freeze_error = true
      receipt = execute(basket, cards, agentic)
      expect(receipt.frozen).to be(false)
      expect(receipt.anomalies.join).to match(/freeze failed/)
    end

    it "does nothing else when provisioning fails" do
      cards, agentic = world(Fakes::Scenario.happy)
      cards.provision_error = true
      expect { execute(basket, cards, agentic) }.to raise_error(Fakes::InjectedFailure)
      expect(ledger.events).to be_empty
    end

    it "refuses an empty basket" do
      cards, agentic = world(Fakes::Scenario.happy)
      expect { execute(Shopper::Basket.fit([], usd(100)), cards, agentic) }.to raise_error(ArgumentError, /empty/)
    end

    it "uses deterministic, per-step idempotency keys" do
      cards, agentic = world(Fakes::Scenario.happy)
      execute(basket, cards, agentic)
      expect(ledger.of(:hold).first[:key]).to eq(Shopper::Reap::Idempotency.key("run1", "Acme", "hold"))
      expect(ledger.of(:capture).first[:key]).to eq(Shopper::Reap::Idempotency.key("run1", "Acme", "capture"))
    end
  end
end
