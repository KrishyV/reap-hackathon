module Fakes
  Card = Shopper::Reap::PrepaidCards::Card
  Hold = Shopper::Reap::PrepaidCards::Hold
  Quote = Shopper::Reap::Agentic::Quote
  Checkout = Shopper::Reap::Agentic::Checkout

  class InjectedFailure < StandardError; end

  # Per-merchant behaviour for a single executor run.
  # failure: nil or one of :quote, :shipping, :hold, :checkout, :poll, :capture, :release
  Scenario = Struct.new(:surcharge_cents, :decline, :status, :polls, :final_delta_cents, :failure, keyword_init: true) do
    def self.happy = new(surcharge_cents: 0, decline: false, status: "COMPLETED", polls: 0, final_delta_cents: nil, failure: nil)
  end

  # Shared, ordered record of everything the fakes were asked to do.
  class Ledger
    attr_reader :events

    def initialize = @events = []
    def <<(event) = (@events << event; self)
    def of(type) = @events.select { |e| e[:type] == type }
  end

  class Cards
    attr_reader :ledger, :frozen_ids, :card
    attr_accessor :freeze_error, :provision_error

    def initialize(ledger: Ledger.new, scenarios: Hash.new(Scenario.happy))
      @ledger = ledger
      @scenarios = scenarios
      @frozen_ids = []
      @seq = 0
    end

    def provision(run_id:, budget:, holder:, max_orders:, log: ->(_) {})
      raise InjectedFailure, "provision failed" if provision_error
      @ledger << { type: :provision, run_id:, budget:, max_orders:, email: holder.fetch(:email) }
      @card = Card.new(id: "card_#{run_id}", user_id: "u1", account_id: "a1", last4: "4242", budget:)
    end

    def hold!(card_id:, amount:, merchant:, idempotency_key:)
      sc = @scenarios[merchant]
      raise InjectedFailure, "hold exploded" if sc.failure == :hold
      raise Shopper::Reap::PrepaidCards::Declined, "INSUFFICIENT_FUNDS" if sc.decline
      raise "hold on frozen card" if frozen_ids.include?(card_id)
      hold = Hold.new(transaction_id: "tx#{@seq += 1}", amount:)
      @ledger << { type: :hold, merchant:, tx: hold.transaction_id, amount:, key: idempotency_key }
      hold
    end

    def capture!(card_id:, hold:, amount:, idempotency_key:)
      @ledger << { type: :capture, tx: hold.transaction_id, amount:, key: idempotency_key }
      raise InjectedFailure, "capture exploded" if scenario_for(hold).failure == :capture
      { "status" => "CLEARED" }
    end

    def release!(card_id:, hold:, idempotency_key:)
      @ledger << { type: :release, tx: hold.transaction_id, amount: hold.amount, key: idempotency_key }
      raise InjectedFailure, "release exploded" if scenario_for(hold).failure == :release
      { "status" => "REVERSED" }
    end

    def freeze!(card_id)
      raise InjectedFailure, "freeze failed" if freeze_error
      @frozen_ids << card_id
      @ledger << { type: :freeze, card_id: }
      { "status" => "FROZEN" }
    end

    def reveal_url(card_id) = "https://reveal.example/#{card_id}"

    private

    def scenario_for(hold)
      merchant = @ledger.of(:hold).find { |e| e[:tx] == hold.transaction_id }.fetch(:merchant)
      @scenarios[merchant]
    end
  end

  # variant ids are "<merchant>::<anything>" so quotes can be attributed to a merchant.
  class Agentic
    attr_reader :ledger

    def initialize(ledger: Ledger.new, scenarios: Hash.new(Scenario.happy), prices: {})
      @ledger = ledger
      @scenarios = scenarios
      @prices = prices # variant_id => Money
      @quotes = {}
      @checkouts = {}
      @seq = 0
    end

    def create_quote(items:, email:, address:, idempotency_key:)
      merchant = items.first.first.split("::").first
      sc = @scenarios[merchant]
      raise InjectedFailure, "quote exploded" if sc.failure == :quote
      # Quotes are in the merchant's own currency (the price it lists natively).
      cur = @prices.fetch(items.first.first).currency
      subtotal = items.sum { |variant, qty| @prices.fetch(variant).cents * qty }
      total = subtotal + sc.surcharge_cents
      id = "q#{@seq += 1}"
      @quotes[id] = merchant
      @ledger << { type: :quote, merchant:, id:, total: Shopper::Money.new(total, cur), items: }
      Quote.new(id:, total: Shopper::Money.new(total, cur), subtotal: Shopper::Money.new(subtotal, cur),
                shipping: Shopper::Money.new(sc.surcharge_cents, cur), tax: Shopper::Money.zero(cur), shipping_options: [])
    end

    def cheapest_shipping!(quote)
      raise InjectedFailure, "shipping exploded" if @scenarios[@quotes.fetch(quote.id)].failure == :shipping
      quote
    end

    def create_checkout(quote_id:, enrollment_id:, return_url:, idempotency_key:)
      merchant = @quotes.fetch(quote_id)
      sc = @scenarios[merchant]
      @ledger << { type: :checkout, merchant:, quote_id:, enrollment_id: }
      raise InjectedFailure, "checkout exploded" if sc.failure == :checkout
      id = "co#{@seq += 1}"
      @checkouts[id] = { merchant:, quote_id:, polls_left: sc.polls }
      build_checkout(id)
    end

    def checkout(id)
      state = @checkouts.fetch(id)
      raise InjectedFailure, "poll exploded" if @scenarios[state[:merchant]].failure == :poll
      state[:polls_left] -= 1
      build_checkout(id)
    end

    def quote_total(quote_id) = @ledger.of(:quote).find { |e| e[:id] == quote_id }[:total]

    # ---- Enrollments (card setup) ----
    def enrollment_store = (@enrollments ||= {})

    def create_enrollment(owner_id:, email:, return_url:)
      id = SecureRandom.uuid
      @ledger << { type: :enrollment, id:, owner_id:, email:, return_url: }
      enrollment_store[id] = {
        "id" => id, "status" => "REQUIRES_ACTION", "owner" => { "type" => "CLIENT_REFERENCE", "id" => owner_id, "email" => email },
        "paymentMethod" => nil, "updatedAt" => Time.now.utc.iso8601(3),
        "nextAction" => { "type" => "REDIRECT", "url" => "https://collect.example/?session=#{id}", "expiresAt" => (Time.now + 900).utc.iso8601 }
      }
    end

    def activate!(id, last4: "7797", updated_at: Time.now.utc.iso8601(3))
      enrollment_store.fetch(id).merge!("status" => "ACTIVE", "nextAction" => nil, "updatedAt" => updated_at,
                                        "paymentMethod" => { "type" => "CARD", "network" => "VISA", "last4" => last4, "expiryMonth" => 12, "expiryYear" => 2027 })
    end

    def enrollment(id)
      enrollment_store.fetch(id) { raise Shopper::Reap::Error.new(status: 404, code: "NOT_FOUND", message: "no enrollment") }
    end

    def enrollments(owner_id:, limit: 50) = enrollment_store.values.select { _1.dig("owner", "id") == owner_id }

    private

    def build_checkout(id)
      state = @checkouts.fetch(id)
      sc = @scenarios[state[:merchant]]
      return Checkout.new(id:, status: "PENDING_APPROVAL", approval_url: "https://approve.example/#{id}") if state[:polls_left].positive?

      final = nil
      if sc.status == "COMPLETED" && sc.final_delta_cents
        qt = quote_total(state[:quote_id])
        final = Shopper::Money.new([qt.cents + sc.final_delta_cents, 0].max, qt.currency)
      end
      Checkout.new(id:, status: sc.status, order_id: sc.status == "COMPLETED" ? "ord_#{id}" : nil, final_amount: final)
    end
  end

  class Researcher
    attr_reader :calls

    def initialize(items) = (@items = items; @calls = [])

    def propose(goal:, budget:, ship_country: "US", log: ->(_) {})
      @calls << { goal:, budget:, ship_country: }
      log.("fake research for #{goal}")
      [@items, Shopper::Basket.fit(@items, budget)]
    end
  end

  module_function

  def option(merchant:, cents:, id: nil)
    id ||= "#{merchant}-#{cents}-#{rand(1_000_000)}"
    Shopper::Option.new(product_id: id, variant_id: "#{merchant}::#{id}", name: "Product #{id}",
                        merchant:, unit_price: Shopper::Money.new(cents), reason: "test")
  end

  # A merchant pricing natively in another currency: unit_price is the budget-currency
  # estimate (as the Researcher would compute), original_price the native price.
  def foreign_option(merchant:, native_cents:, currency:, fx:, id: nil)
    id ||= "#{merchant}-#{native_cents}-#{rand(1_000_000)}"
    native = Shopper::Money.new(native_cents, currency)
    Shopper::Option.new(product_id: id, variant_id: "#{merchant}::#{id}", name: "Product #{id}", merchant:,
                        unit_price: fx.estimate(native, to: "USD"), original_price: native, reason: "test")
  end

  # The merchant quotes in its native currency.
  def prices_for(items) = items.flat_map(&:options).to_h { |o| [o.variant_id, o.original_price || o.unit_price] }
end
