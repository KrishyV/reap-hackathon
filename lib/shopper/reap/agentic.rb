require_relative "client"
require_relative "../money"
require_relative "../log"

module Shopper
  module Reap
    class Agentic
      Quote = Struct.new(:id, :total, :shipping, :tax, :subtotal, :expires_at, :shipping_options, keyword_init: true)
      Checkout = Struct.new(:id, :status, :approval_url, :order_id, :final_amount, keyword_init: true) do
        def terminal? = %w[COMPLETED FAILED EXPIRED].include?(status)
      end

      DETAILS_BATCH = 5

      def initialize(client:, simulate_checkout: client.sandbox?)
        @client = client
        @simulate_checkout = simulate_checkout
      end

      # country/currency describe the shopper (delivery country, budget currency). Merchants
      # abroad may still return prices in their own currency; callers convert.
      def search(query, max_price: nil, limit: 6, country: "US", currency: "USD")
        body = { query:, context: { country:, currency: }, filters: { availability: "AVAILABLE_ONLY" }, pagination: { limit: } }
        body[:filters][:price] = { min: "0", max: max_price.to_decimal_string } if max_price
        products = @client.post("/agentic/products/search", body).fetch("products", [])
        Log.debug("agentic.search", query:, country:, currency:, results: products.size,
                                    merchants: products.map { _1.dig("merchant", "name") }.tally)
        products
      end

      def details(product_ids)
        return [] if product_ids.empty?
        # The details endpoint rejects large id lists, so batch.
        product_ids.each_slice(DETAILS_BATCH).flat_map do |ids|
          @client.post("/agentic/products/details", { productIds: ids }).fetch("products", [])
        end
      end

      def create_enrollment(owner_id:, email:, return_url:)
        e = @client.post("/agentic/enrollments", {
          source: "EXTERNAL",
          owner: { type: "CLIENT_REFERENCE", id: owner_id, email: },
          presentation: { type: "REDIRECT", returnUrl: return_url }
        })
        Log.info("agentic.enrollment_created", enrollment_id: e["id"], status: e["status"], owner_id:)
        e
      end

      def enrollment(id)
        e = @client.get("/agentic/enrollments/#{id}")
        Log.debug("agentic.enrollment", enrollment_id: id, status: e["status"])
        e
      end

      def create_quote(items:, email:, address:, idempotency_key:)
        q = to_quote(@client.post("/agentic/quotes", {
          items: items.map { |variant_id, qty| { variantId: variant_id, quantity: qty } },
          email:, shippingAddress: address
        }, idempotency_key:))
        log_quote("agentic.quote_created", q, items: items.size, ship_country: address[:country])
        q
      end

      # Picks the cheapest shipping option; reprices the quote only if it changes.
      def cheapest_shipping!(quote)
        cheapest = quote.shipping_options.min_by { |o| [Money.from_api(o["price"]).cents, o["id"]] }
        Log.debug("agentic.shipping_options", quote_id: quote.id,
                                              options: quote.shipping_options.map { |o| "#{o['id']}:#{o.dig('price', 'amount')}#{o['selected'] ? '*' : ''}" })
        return quote if cheapest.nil? || cheapest["selected"]
        q = to_quote(@client.post("/agentic/quotes/#{quote.id}/shipping-option", { shippingOptionId: cheapest["id"] }))
        log_quote("agentic.quote_reshipped", q, shipping_option: cheapest["id"], previous_total: quote.total)
        q
      end

      def create_checkout(quote_id:, enrollment_id:, return_url:, idempotency_key:)
        headers = @simulate_checkout ? { "X-Simulate-Checkout" => "COMPLETED" } : {}
        c = to_checkout(@client.post("/agentic/checkouts", {
          quoteId: quote_id, enrollmentId: enrollment_id,
          presentation: { type: "REDIRECT", returnUrl: return_url }
        }, idempotency_key:, headers:))
        Log.info("agentic.checkout_created", checkout_id: c.id, quote_id:, status: c.status, simulated: @simulate_checkout,
                                             needs_approval: !c.approval_url.nil?)
        c
      end

      def checkout(id)
        c = to_checkout(@client.get("/agentic/checkouts/#{id}"))
        Log.debug("agentic.checkout_polled", checkout_id: id, status: c.status, order_id: c.order_id, final_amount: c.final_amount)
        c
      end

      private

      def log_quote(event, q, **extra)
        Log.info(event, quote_id: q.id, total: q.total, subtotal: q.subtotal, shipping: q.shipping, tax: q.tax,
                        currency: q.total.currency, expires_at: q.expires_at, shipping_options: q.shipping_options.size, **extra)
      end

      def to_quote(raw)
        b = raw.fetch("amountBreakdown")
        Quote.new(
          id: raw.fetch("id"),
          total: Money.from_api(b.fetch("finalAmount")),
          subtotal: Money.from_api(b.fetch("itemsSubtotal")),
          shipping: b["shipping"] ? Money.from_api(b["shipping"]) : Money.zero(b.dig("finalAmount", "currency") || "USD"),
          tax: b.dig("tax", "amount") ? Money.from_api(b.dig("tax", "amount")) : Money.zero(b.dig("finalAmount", "currency") || "USD"),
          expires_at: raw["expiresAt"],
          shipping_options: raw.fetch("shippingOptions", [])
        )
      end

      def to_checkout(raw)
        Checkout.new(
          id: raw.fetch("id"), status: raw.fetch("status"),
          approval_url: raw.dig("nextAction", "url"),
          order_id: raw["orderId"],
          final_amount: raw["finalAmount"] ? Money.from_api(raw["finalAmount"]) : (raw["amount"] && Money.from_api(raw["amount"]))
        )
      end
    end
  end
end
