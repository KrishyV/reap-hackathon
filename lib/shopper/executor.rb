require_relative "money"
require_relative "basket"
require_relative "budget_guard"
require_relative "reap/client"
require_relative "reap/prepaid_cards"
require_relative "reap/agentic"

module Shopper
  # Turns an approved basket into placed orders. One prepaid card per run, one
  # quote + hold + checkout per merchant. The card is always frozen at the end.
  class Executor
    Order = Struct.new(:merchant, :picks, :status, :quote, :checkout_id, :order_id, :final_amount,
                       :approval_url, :error, :dropped, keyword_init: true) do
      def to_h_public
        {
          merchant:, status:, order_id:, checkout_id:, approval_url:, error:,
          items: picks.map { |p| { name: p.option.name, quantity: p.item.quantity, unit_price: p.option.unit_price.to_s, need: p.item.name } },
          dropped: (dropped || []).map { |p| p.item.name },
          subtotal: quote&.subtotal&.to_s, shipping: quote&.shipping&.to_s, tax: quote&.tax&.to_s,
          quoted_total: quote&.total&.to_s, final_amount: final_amount&.to_s
        }
      end
    end

    Receipt = Struct.new(:card, :budget, :orders, :spent, :frozen, :anomalies, keyword_init: true)

    POLL_INTERVAL = 3

    def initialize(cards:, agentic:, sleeper: ->(s) { sleep(s) }, approval_timeout: 600, clock: -> { Time.now })
      @cards = cards
      @agentic = agentic
      @sleeper = sleeper
      @approval_timeout = approval_timeout
      @clock = clock
    end

    def run(run_id:, basket:, holder:, address:, enrollment_id:, return_url:,
            log: ->(_) {}, on_card: ->(_) {}, on_order: ->(_) {})
      budget = basket.budget
      guard = BudgetGuard.new(budget)
      groups = basket.by_merchant
      orders = []
      anomalies = []
      card = nil
      frozen = false

      raise ArgumentError, "basket is empty" if groups.empty?

      begin
        card = @cards.provision(run_id:, budget:, holder:, max_orders: groups.size, log:)
        on_card.(card)

        groups.each do |merchant, picks|
          order = place_order(run_id:, card:, guard:, merchant:, picks:, holder:, address:,
                              enrollment_id:, return_url:, log:, anomalies:, on_order:)
          orders << order
          on_order.(order)
        end
      ensure
        if card
          begin
            @cards.freeze!(card.id)
            frozen = true
            log.("Froze card •••• #{card.last4}; it can never be charged again")
          rescue StandardError => e
            anomalies << "Card freeze failed: #{e.message}"
            log.("WARNING: failed to freeze card: #{e.message}")
          end
        end
      end

      raise "budget invariant violated" unless guard.invariant_ok?
      Receipt.new(card:, budget:, orders:, spent: guard.spent, frozen:, anomalies:)
    end

    private

    def place_order(run_id:, card:, guard:, merchant:, picks:, holder:, address:, enrollment_id:, return_url:, log:, anomalies:, on_order:)
      key = ->(*step) { Reap::Idempotency.key(run_id, merchant, *step) }
      remaining = picks.sort_by { |p| [p.item.priority, p.item.key.to_s] }
      dropped = []
      order = Order.new(merchant:, picks: remaining, status: "QUOTING", dropped:)
      attempt = 0

      quote = nil
      loop do
        return order.tap { |o| o.status = "SKIPPED"; o.error = "Nothing left within budget" } if remaining.empty?
        attempt += 1
        quote = @agentic.create_quote(
          items: remaining.map { |p| [p.option.variant_id, p.item.quantity] },
          email: holder.fetch(:email), address:, idempotency_key: key.("quote", attempt)
        )
        quote = @agentic.cheapest_shipping!(quote)
        log.("#{merchant}: quoted #{quote.total} (items #{quote.subtotal}, shipping #{quote.shipping}, tax #{quote.tax})")
        break if guard.can_reserve?(quote.total)

        victim = remaining.pop
        dropped << victim
        log.("#{merchant}: #{quote.total} exceeds remaining budget #{guard.remaining}; dropping lowest-priority item '#{victim.item.name}'")
      end
      order.picks = remaining
      order.quote = quote

      hold_id = key.("hold")
      begin
        hold = @cards.hold!(card_id: card.id, amount: quote.total, merchant:, idempotency_key: hold_id)
      rescue Reap::PrepaidCards::Declined => e
        log.("#{merchant}: prepaid card declined the hold (#{e.reason}); not checking out")
        order.status = "DECLINED"
        order.error = e.reason
        return order
      end
      guard.reserve!(hold_id, quote.total)
      log.("#{merchant}: held #{quote.total} on card •••• #{card.last4}")

      begin
        checkout = @agentic.create_checkout(quote_id: quote.id, enrollment_id:, return_url:, idempotency_key: key.("checkout"))
        order.checkout_id = checkout.id
        if checkout.approval_url && !checkout.terminal?
          order.approval_url = checkout.approval_url
          order.status = "AWAITING_APPROVAL"
          on_order.(order)
          log.("#{merchant}: waiting for your approval on Reap's hosted page")
        end
        checkout = poll(checkout)
      rescue StandardError => e
        release(card, hold, key, guard, hold_id, anomalies, log, merchant)
        order.status = "FAILED"
        order.error = e.message
        log.("#{merchant}: checkout failed (#{e.message}); hold released")
        return order
      end

      if checkout.status == "COMPLETED"
        final = checkout.final_amount || quote.total
        if final > quote.total
          anomalies << "#{merchant}: final #{final} exceeded quote #{quote.total}"
          final = quote.total
        end
        begin
          @cards.capture!(card_id: card.id, hold:, amount: final, idempotency_key: key.("capture"))
        rescue StandardError => e
          anomalies << "#{merchant}: failed to clear hold on card: #{e.message}"
        end
        guard.capture!(hold_id, final)
        order.status = "COMPLETED"
        order.order_id = checkout.order_id
        order.final_amount = final
        log.("#{merchant}: order placed#{checkout.order_id ? " (#{checkout.order_id})" : ''}, charged #{final}")
      else
        release(card, hold, key, guard, hold_id, anomalies, log, merchant)
        order.status = checkout.status
        order.error = "Checkout ended as #{checkout.status}"
        log.("#{merchant}: checkout #{checkout.status}; hold released")
      end
      order
    end

    def poll(checkout)
      deadline = @clock.call + @approval_timeout
      until checkout.terminal?
        raise "Timed out waiting for checkout #{checkout.id}" if @clock.call > deadline
        @sleeper.call(POLL_INTERVAL)
        checkout = @agentic.checkout(checkout.id)
      end
      checkout
    end

    def release(card, hold, key, guard, hold_id, anomalies, log, merchant)
      @cards.release!(card_id: card.id, hold:, idempotency_key: key.("release"))
    rescue StandardError => e
      anomalies << "#{merchant}: failed to release hold: #{e.message}"
      log.("WARNING #{merchant}: failed to release hold: #{e.message}")
    ensure
      guard.release!(hold_id)
    end
  end
end
