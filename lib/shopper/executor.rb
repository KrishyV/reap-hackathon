require_relative "money"
require_relative "basket"
require_relative "budget_guard"
require_relative "fx"
require_relative "log"
require_relative "reap/client"
require_relative "reap/prepaid_cards"
require_relative "reap/agentic"

module Shopper
  # Turns an approved basket into placed orders. One prepaid card per run, one
  # quote + hold + checkout per merchant. The card is always frozen at the end.
  #
  # International merchants quote in their own currency. The card, the guard and
  # every hold stay in the budget currency: a foreign quote is converted with a
  # conservative estimate (rate + card FX markup + drift buffer, rounded up) before
  # it is reserved, and the capture is the settled conversion capped at that hold.
  class Executor
    Order = Struct.new(:merchant, :picks, :status, :quote, :checkout_id, :order_id, :final_amount,
                       :approval_url, :error, :dropped, :charge_estimate, :fx, :final_native, keyword_init: true) do
      def to_h_public
        {
          merchant:, status:, order_id:, checkout_id:, approval_url:, error:,
          items: picks.map do |p|
            { name: p.option.name, quantity: p.item.quantity, unit_price: p.option.unit_price.to_s, need: p.item.name,
              original_price: p.option.respond_to?(:foreign?) && p.option.foreign? ? p.option.original_price.to_s : nil }
          end,
          dropped: (dropped || []).map { |p| p.item.name },
          subtotal: quote&.subtotal&.to_s, shipping: quote&.shipping&.to_s, tax: quote&.tax&.to_s,
          quoted_total: quote&.total&.to_s, charge_estimate: charge_estimate&.to_s,
          fx: fx&.to_h_public, final_native: final_native&.to_s, final_amount: final_amount&.to_s
        }
      end
    end

    Receipt = Struct.new(:card, :budget, :orders, :spent, :frozen, :anomalies, keyword_init: true)

    POLL_INTERVAL = 3

    def initialize(cards:, agentic:, fx: FX.offline, sleeper: ->(s) { sleep(s) }, approval_timeout: 600, clock: -> { Time.now })
      @cards = cards
      @agentic = agentic
      @fx = fx
      @sleeper = sleeper
      @approval_timeout = approval_timeout
      @clock = clock
    end

    def run(run_id:, basket:, holder:, address:, enrollment_id:, return_url:,
            log: ->(_) {}, on_card: ->(_) {}, on_order: ->(_) {})
      Log.with(run_id:, component: "executor") do
        execute(run_id:, basket:, holder:, address:, enrollment_id:, return_url:, log:, on_card:, on_order:)
      end
    end

    private

    def execute(run_id:, basket:, holder:, address:, enrollment_id:, return_url:, log:, on_card:, on_order:)
      budget = basket.budget
      guard = BudgetGuard.new(budget)
      groups = basket.by_merchant
      orders = []
      anomalies = []
      card = nil
      frozen = false

      raise ArgumentError, "basket is empty" if groups.empty?
      Log.info("executor.start", budget:, merchants: groups.keys, picks: basket.picks.size,
                                 ship_country: address[:country], enrollment: !enrollment_id.to_s.empty?)

      begin
        card = Log.time("executor.provision", level: :info, max_orders: groups.size) do
          @cards.provision(run_id:, budget:, holder:, max_orders: groups.size, log:)
        end
        on_card.(card)
        fx = fx_for(card, basket)

        groups.each do |merchant, picks|
          order = Log.with(merchant:) do
            place_order(run_id:, card:, guard:, fx:, merchant:, picks:, holder:, address:,
                        enrollment_id:, return_url:, log:, anomalies:, on_order:)
          end
          Log.info("executor.order_finished", merchant:, status: order.status, error: order.error,
                                              charged: order.final_amount, spent: guard.spent, remaining: guard.remaining)
          orders << order
          on_order.(order)
        end
      rescue StandardError => e
        Log.exception("executor.aborted", e, orders_done: orders.size)
        raise
      ensure
        if card
          begin
            @cards.freeze!(card.id)
            frozen = true
            log.("Froze card •••• #{card.last4}; it can never be charged again")
          rescue StandardError => e
            anomalies << "Card freeze failed: #{e.message}"
            Log.exception("executor.freeze_failed", e, card_id: card.id)
            log.("WARNING: failed to freeze card: #{e.message}")
          end
        end
      end

      unless guard.invariant_ok?
        Log.error("executor.invariant_violated", spent: guard.spent, held: guard.held, budget:)
        raise "budget invariant violated"
      end
      anomalies.each { |a| Log.warn("executor.anomaly", detail: a) }
      Log.info("executor.done", spent: guard.spent, unspent: budget - guard.spent, frozen:,
                                statuses: orders.map(&:status).tally, anomalies: anomalies.size)
      Receipt.new(card:, budget:, orders:, spent: guard.spent, frozen:, anomalies:)
    end

    # Use the card account's real FX markup when the basket has foreign merchants.
    def fx_for(card, basket)
      foreign = basket.picks.any? { |p| p.option.respond_to?(:foreign?) && p.option.foreign? }
      return @fx unless foreign && @cards.respond_to?(:fx_markup_bps)
      bps = @cards.fx_markup_bps(card.account_id)
      return @fx if bps.nil? || bps == @fx.markup_bps
      Log.info("executor.fx_markup_override", assumed_bps: @fx.markup_bps, actual_bps: bps)
      @fx.with_markup(bps)
    end

    def place_order(run_id:, card:, guard:, fx:, merchant:, picks:, holder:, address:, enrollment_id:, return_url:, log:, anomalies:, on_order:)
      key = ->(*step) { Reap::Idempotency.key(run_id, merchant, *step) }
      remaining = picks.sort_by { |p| [p.item.priority, p.item.key.to_s] }
      dropped = []
      order = Order.new(merchant:, picks: remaining, status: "QUOTING", dropped:)
      attempt = 0
      currency = guard.budget.currency
      Log.info("order.start", items: remaining.map { |p| "#{p.item.name}x#{p.item.quantity}" }, remaining_budget: guard.remaining)

      quote = nil
      charge = nil
      loop do
        if remaining.empty?
          Log.warn("order.skipped", reason: "nothing left within budget", dropped: dropped.map { _1.item.name })
          return order.tap { |o| o.status = "SKIPPED"; o.error = "Nothing left within budget" }
        end
        attempt += 1
        quote = Log.time("order.quote", level: :info, attempt:, items: remaining.size) do
          @agentic.create_quote(
            items: remaining.map { |p| [p.option.variant_id, p.item.quantity] },
            email: holder.fetch(:email), address:, idempotency_key: key.("quote", attempt)
          )
        end
        quote = @agentic.cheapest_shipping!(quote)
        begin
          charge = fx.estimate(quote.total, to: currency)
        rescue FX::Unavailable => e
          Log.error("order.fx_unavailable", quote_total: quote.total, error_message: e.message)
          log.("#{merchant}: can't convert #{quote.total.currency} to #{currency} right now; skipping")
          order.quote = quote
          order.status = "FAILED"
          order.error = "No exchange rate for #{quote.total.currency}"
          return order
        end
        conversion = fx.describe(quote.total, to: currency)
        Log.info("order.quoted", quote_id: quote.id, total: quote.total, charge_estimate: charge,
                                 fx: conversion&.to_h_public, remaining_budget: guard.remaining)
        log.("#{merchant}: quoted #{quote.total} (items #{quote.subtotal}, shipping #{quote.shipping}, tax #{quote.tax})" \
             "#{conversion ? " ≈ #{charge} incl. FX fee & buffer" : ''}")
        order.fx = conversion
        break if guard.can_reserve?(charge)

        victim = remaining.pop
        dropped << victim
        Log.warn("order.drop_to_fit", item: victim.item.name, priority: victim.item.priority, charge_estimate: charge,
                                      remaining_budget: guard.remaining)
        log.("#{merchant}: #{charge} exceeds remaining budget #{guard.remaining}; dropping lowest-priority item '#{victim.item.name}'")
      end
      order.picks = remaining
      order.quote = quote
      order.charge_estimate = charge

      hold_id = key.("hold")
      begin
        hold = @cards.hold!(card_id: card.id, amount: charge, merchant:, idempotency_key: hold_id)
      rescue Reap::PrepaidCards::Declined => e
        Log.warn("order.declined", amount: charge, reason: e.reason)
        log.("#{merchant}: prepaid card declined the hold (#{e.reason}); not checking out")
        order.status = "DECLINED"
        order.error = e.reason
        return order
      end
      guard.reserve!(hold_id, charge)
      log.("#{merchant}: held #{charge} on card •••• #{card.last4}")

      begin
        checkout = @agentic.create_checkout(quote_id: quote.id, enrollment_id:, return_url:, idempotency_key: key.("checkout"))
        order.checkout_id = checkout.id
        if checkout.approval_url && !checkout.terminal?
          order.approval_url = checkout.approval_url
          order.status = "AWAITING_APPROVAL"
          on_order.(order)
          Log.info("order.awaiting_approval", checkout_id: checkout.id)
          log.("#{merchant}: waiting for your approval on Reap's hosted page")
        end
        checkout = Log.time("order.poll", level: :info, checkout_id: checkout.id) { poll(checkout) }
      rescue StandardError => e
        Log.exception("order.checkout_failed", e, checkout_id: order.checkout_id)
        release(card, hold, key, guard, hold_id, anomalies, log, merchant)
        order.status = "FAILED"
        order.error = e.message
        log.("#{merchant}: checkout failed (#{e.message}); hold released")
        return order
      end

      if checkout.status == "COMPLETED"
        final = settle(checkout, quote, charge, fx, currency, merchant, anomalies, order)
        begin
          @cards.capture!(card_id: card.id, hold:, amount: final, idempotency_key: key.("capture"))
        rescue StandardError => e
          Log.exception("order.capture_failed", e, amount: final)
          anomalies << "#{merchant}: failed to clear hold on card: #{e.message}"
        end
        guard.capture!(hold_id, final)
        order.status = "COMPLETED"
        order.order_id = checkout.order_id
        order.final_amount = final
        Log.info("order.completed", order_id: checkout.order_id, charged: final, final_native: order.final_native, held: charge)
        log.("#{merchant}: order placed#{checkout.order_id ? " (#{checkout.order_id})" : ''}, charged #{final}")
      else
        Log.warn("order.not_completed", checkout_id: checkout.id, status: checkout.status)
        release(card, hold, key, guard, hold_id, anomalies, log, merchant)
        order.status = checkout.status
        order.error = "Checkout ended as #{checkout.status}"
        log.("#{merchant}: checkout #{checkout.status}; hold released")
      end
      order
    end

    # Budget-currency amount to capture: never more than the quote, never more than the hold.
    def settle(checkout, quote, charge, fx, currency, merchant, anomalies, order)
      native = checkout.final_amount || quote.total
      if native.currency == quote.total.currency && native > quote.total
        anomalies << "#{merchant}: final #{native} exceeded quote #{quote.total}"
        Log.warn("order.final_above_quote", final: native, quote: quote.total)
        native = quote.total
      end
      order.final_native = native
      final = begin
        fx.settle(native, to: currency)
      rescue FX::Unavailable => e
        Log.warn("order.settle_fx_unavailable", final_native: native, error_message: e.message)
        charge
      end
      if final > charge
        anomalies << "#{merchant}: converted charge #{final} exceeded hold #{charge}"
        Log.warn("order.final_above_hold", final:, hold: charge)
        final = charge
      end
      final
    end

    def poll(checkout)
      deadline = @clock.call + @approval_timeout
      polls = 0
      until checkout.terminal?
        raise "Timed out waiting for checkout #{checkout.id}" if @clock.call > deadline
        @sleeper.call(POLL_INTERVAL)
        polls += 1
        previous = checkout.status
        checkout = @agentic.checkout(checkout.id)
        Log.info("order.status_changed", checkout_id: checkout.id, from: previous, to: checkout.status, polls:) if previous != checkout.status
      end
      checkout
    end

    def release(card, hold, key, guard, hold_id, anomalies, log, merchant)
      @cards.release!(card_id: card.id, hold:, idempotency_key: key.("release"))
    rescue StandardError => e
      Log.exception("order.release_failed", e, amount: hold.amount)
      anomalies << "#{merchant}: failed to release hold: #{e.message}"
      log.("WARNING #{merchant}: failed to release hold: #{e.message}")
    ensure
      guard.release!(hold_id)
    end
  end
end
