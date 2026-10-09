# International shopping: merchants price in GBP/EUR/JPY, the budget, card and
# holds stay in USD, and the agent must still never spend over budget.
RSpec.describe "International shopping" do
  let(:holder) { { first_name: "Ada", last_name: "Lovelace", email: "ada@example.com" } }
  let(:address) { { firstName: "Ada", lastName: "Lovelace", addressLine1: "1 Main St", city: "London", postalCode: "N1", country: "GB" } }

  def fx_with(rates, markup: 150, buffer: 100)
    Shopper::FX.new(source: Shopper::FX::StaticSource.new({ "USD" => rates }), markup_bps: markup, buffer_bps: buffer)
  end

  describe Shopper::Executor do
    INTL_MERCHANTS = { "UKShop" => "GBP", "EuroMart" => "EUR", "USStore" => "USD" }.freeze

    def scenario_gen
      G.fixed_hash(
        surcharge_cents: G.frequency(2 => G.constant(0), 1 => G.choose(1..2_000)),
        decline: G.frequency(6 => G.constant(false), 1 => G.constant(true)),
        status: G.frequency(3 => G.constant("COMPLETED"), 1 => G.constant("FAILED")),
        polls: G.choose(0..1),
        final_delta_cents: G.one_of(G.nil, G.choose(-500..800)),
        failure: G.constant(nil)
      ).map { Fakes::Scenario.new(**_1) }
    end

    def rate_gen = G.choose(300..2_000).map { BigDecimal(_1) / 1000 } # 0.3..2.0 units per USD

    def world_gen
      option = G.tuple(G.choose(100..6_000), G.choose(0..2))
      item = G.tuple(G.choose(1..3), G.choose(1..2), list_of(option, 1, 2))
      G.tuple(list_of(item, 1, 5), G.choose(30..130), list_of(scenario_gen, 3, 3), rate_gen, rate_gen,
              G.choose(0..300), G.choose(0..200))
    end

    it "keeps every hold and capture in USD and never exceeds the budget, whatever the rates and quotes" do
      forall(world_gen, runs: 300) do |(raw, pct, scenarios, gbp, eur, markup, buffer)|
        fx = fx_with({ "GBP" => gbp, "EUR" => eur }, markup:, buffer:)
        names = INTL_MERCHANTS.keys
        items = raw.each_with_index.map do |(priority, qty, opts), i|
          options = opts.each_with_index.map do |(c, m), j|
            name = names[m]
            cur = INTL_MERCHANTS[name]
            if cur == "USD"
              Fakes.option(merchant: name, cents: c, id: "i#{i}o#{j}")
            else
              Fakes.foreign_option(merchant: name, native_cents: c, currency: cur, fx:, id: "i#{i}o#{j}")
            end
          end
          Shopper::Item.new(key: "k#{i}", name: "Need #{i}", priority:, quantity: qty, options:, why: "")
        end
        preferred = items.sum { |it| it.options.first.unit_price.cents * it.quantity }
        basket = Shopper::Basket.fit(items, usd([preferred * pct / 100, 100].max))
        next if basket.picks.empty?

        by_merchant = names.zip(scenarios).to_h
        ledger = Fakes::Ledger.new
        cards = Fakes::Cards.new(ledger:, scenarios: by_merchant)
        agentic = Fakes::Agentic.new(ledger:, scenarios: by_merchant, prices: Fakes.prices_for(items))
        receipt = Shopper::Executor.new(cards:, agentic:, fx:, sleeper: ->(_) {}).run(
          run_id: "r", basket:, holder:, address:, enrollment_id: "e", return_url: "https://x.example/r"
        )

        holds = ledger.of(:hold)
        captures = ledger.of(:capture)
        expect((holds + captures).map { _1[:amount].currency }.uniq - ["USD"]).to be_empty

        # Each hold is the conservative USD estimate of that merchant's native quote.
        holds.each do |h|
          q = ledger.of(:quote).select { _1[:merchant] == h[:merchant] }.last
          expect(q[:total].currency).to eq(INTL_MERCHANTS[h[:merchant]])
          expect(h[:amount]).to eq(fx.estimate(q[:total], to: "USD"))
        end

        # Captures never exceed their hold; total spend never exceeds the budget at any point.
        outstanding = {}
        captured = Shopper::Money.zero
        ledger.events.each do |e|
          case e[:type]
          when :hold then outstanding[e[:tx]] = e[:amount]
          when :capture
            expect(e[:amount]).to be <= outstanding.fetch(e[:tx])
            outstanding.delete(e[:tx])
            captured += e[:amount]
          when :release then outstanding.delete(e[:tx])
          end
          expect(captured + Shopper::Money.sum(outstanding.values)).to be <= basket.budget
        end
        expect(receipt.spent).to eq(captured)
        expect(cards.frozen_ids).to eq([cards.card.id])

        receipt.orders.select { _1.status == "COMPLETED" && INTL_MERCHANTS[_1.merchant] != "USD" }.each do |o|
          expect(o.fx).not_to be_nil
          expect(o.final_native.currency).to eq(INTL_MERCHANTS[o.merchant])
          expect(o.final_amount).to eq([fx.settle([o.final_native, o.quote.total].min, to: "USD"), o.charge_estimate].min)
        end
      end
    end

    it "does not hold or check out when no rate is available for the merchant's currency" do
      fx = fx_with({ "GBP" => "0.8" })
      gbp_opt = Fakes.foreign_option(merchant: "UKShop", native_cents: 2_000, currency: "GBP", fx:, id: "g")
      jpy = Shopper::Option.new(product_id: "j", variant_id: "JPShop::j", name: "Kit", merchant: "JPShop",
                                unit_price: usd(1_000), original_price: Shopper::Money.new(150_000, "JPY"), reason: "")
      items = [Shopper::Item.new(key: "a", name: "A", priority: 1, quantity: 1, options: [gbp_opt], why: ""),
               Shopper::Item.new(key: "b", name: "B", priority: 1, quantity: 1, options: [jpy], why: "")]
      basket = Shopper::Basket.fit(items, usd(10_000))
      ledger = Fakes::Ledger.new
      cards = Fakes::Cards.new(ledger:)
      agentic = Fakes::Agentic.new(ledger:, prices: Fakes.prices_for(items))
      receipt = Shopper::Executor.new(cards:, agentic:, fx:, sleeper: ->(_) {}).run(
        run_id: "r", basket:, holder:, address:, enrollment_id: "e", return_url: "https://x.example/r"
      )
      jp = receipt.orders.find { _1.merchant == "JPShop" }
      expect(jp.status).to eq("FAILED")
      expect(ledger.of(:hold).map { _1[:merchant] }).to eq(["UKShop"])
      expect(ledger.of(:checkout).map { _1[:merchant] }).to eq(["UKShop"])
      expect(receipt.orders.find { _1.merchant == "UKShop" }.status).to eq("COMPLETED")
    end

    it "prices holds with the card account's real FX markup when Reap reports one" do
      fx = fx_with({ "GBP" => "0.75" }, markup: 150, buffer: 0)
      opt = Fakes.foreign_option(merchant: "UKShop", native_cents: 7_500, currency: "GBP", fx: fx_with({ "GBP" => "0.75" }, markup: 300, buffer: 0), id: "g")
      items = [Shopper::Item.new(key: "a", name: "A", priority: 1, quantity: 1, options: [opt], why: "")]
      ledger = Fakes::Ledger.new
      cards = Fakes::Cards.new(ledger:)
      cards.define_singleton_method(:fx_markup_bps) { |_account| 300 }
      agentic = Fakes::Agentic.new(ledger:, prices: Fakes.prices_for(items))
      Shopper::Executor.new(cards:, agentic:, fx:, sleeper: ->(_) {}).run(
        run_id: "r", basket: Shopper::Basket.fit(items, usd(20_000)), holder:, address:, enrollment_id: "e", return_url: "https://x.example/r"
      )
      expect(ledger.of(:hold).first[:amount]).to eq(usd(10_300)) # £75 → $100 + 3%
    end
  end

  describe Shopper::Basket do
    it "never mixes currencies: options not in the budget currency are excluded and logged" do
      raw = Shopper::Option.new(product_id: "x", variant_id: "M::x", name: "X", merchant: "M", unit_price: Shopper::Money.new(500, "GBP"), reason: "")
      ok = Fakes.option(merchant: "N", cents: 700, id: "y")
      items = [Shopper::Item.new(key: "a", name: "A", priority: 1, quantity: 1, options: [raw, ok], why: "")]
      basket = Shopper::Basket.fit(items, usd(1_000))
      expect(basket.picks.map { _1.option.product_id }).to eq(["y"])
      expect(Shopper::Log.recent(event: "basket.currency_excluded")).not_to be_empty
    end
  end

  describe Shopper::Researcher do
    let(:planner) do
      Class.new do
        def plan(_goal, _budget) = [{ key: "n1", name: "Kettle", query: "kettle", priority: 1, quantity: 1, why: "" }]
        def rank(_g, _b, _needs, candidates) = Shopper::Planner.sanitize_rankings({}, candidates)
      end.new
    end

    let(:agentic) do
      products = {
        "uk" => ["UKShop", 30.0, "GBP"], "us" => ["USStore", 45.0, "USD"], "jp" => ["JPShop", 5000.0, "JPY"]
      }
      Class.new do
        attr_reader :contexts

        define_method(:initialize) { @contexts = [] }
        define_method(:search) do |_q, max_price:, country: "US", currency: "USD", **|
          @contexts << [country, currency]
          products.map { |id, (m, amt, cur)| { "id" => id, "name" => id, "merchant" => { "name" => m }, "previewVariant" => { "price" => { "amount" => amt, "currency" => cur } } } }
        end
        define_method(:details) do |ids|
          ids.map do |id|
            m, amt, cur = products.fetch(id)
            { "id" => id, "name" => id, "merchant" => { "name" => m },
              "defaultVariant" => { "id" => "v-#{id}", "available" => true, "price" => { "amount" => amt, "currency" => cur } } }
          end
        end
      end.new
    end

    it "converts foreign prices to budget-currency estimates, keeps the native price, and skips unconvertible ones" do
      fx = fx_with({ "GBP" => "0.75" }, markup: 150, buffer: 100)
      logs = []
      items, = described_class.new(planner:, agentic:, fx:, sleeper: ->(_) {})
                              .propose(goal: "tea", budget: usd(10_000), ship_country: "GB", log: ->(m) { logs << m })
      opts = items.first.options.to_h { [_1.merchant, _1] }
      expect(opts.keys).to contain_exactly("UKShop", "USStore")
      expect(opts["UKShop"].original_price).to eq(Shopper::Money.new(3_000, "GBP"))
      expect(opts["UKShop"].unit_price).to eq(usd(4_100)) # £30 / 0.75 = $40, +2.5%
      expect(opts["UKShop"].foreign?).to be(true)
      expect(opts["USStore"].foreign?).to be_falsey
      expect(agentic.contexts.uniq).to eq([%w[GB USD]])
    end
  end
end
