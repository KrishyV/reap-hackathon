require_relative "client"
require_relative "../money"

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

      def search(query, max_price: nil, limit: 6)
        body = { query:, context: { country: "US", currency: "USD" }, filters: { availability: "AVAILABLE_ONLY" }, pagination: { limit: } }
        body[:filters][:price] = { min: "0", max: max_price.to_decimal_string } if max_price
        @client.post("/agentic/products/search", body).fetch("products", [])
      end

      def details(product_ids)
        return [] if product_ids.empty?
        # The details endpoint rejects large id lists, so batch.
        product_ids.each_slice(DETAILS_BATCH).flat_map do |ids|
          @client.post("/agentic/products/details", { productIds: ids }).fetch("products", [])
        end
      end

      def create_enrollment(owner_id:, email:, return_url:)
        @client.post("/agentic/enrollments", {
          source: "EXTERNAL",
          owner: { type: "CLIENT_REFERENCE", id: owner_id, email: },
          presentation: { type: "REDIRECT", returnUrl: return_url }
        })
      end

      def enrollment(id) = @client.get("/agentic/enrollments/#{id}")

      def create_quote(items:, email:, address:, idempotency_key:)
        to_quote(@client.post("/agentic/quotes", {
          items: items.map { |variant_id, qty| { variantId: variant_id, quantity: qty } },
          email:, shippingAddress: address
        }, idempotency_key:))
      end

      # Picks the cheapest shipping option; reprices the quote only if it changes.
      def cheapest_shipping!(quote)
        cheapest = quote.shipping_options.min_by { |o| [Money.from_api(o["price"]).cents, o["id"]] }
        return quote if cheapest.nil? || cheapest["selected"]
        to_quote(@client.post("/agentic/quotes/#{quote.id}/shipping-option", { shippingOptionId: cheapest["id"] }))
      end

      def create_checkout(quote_id:, enrollment_id:, return_url:, idempotency_key:)
        headers = @simulate_checkout ? { "X-Simulate-Checkout" => "COMPLETED" } : {}
        to_checkout(@client.post("/agentic/checkouts", {
          quoteId: quote_id, enrollmentId: enrollment_id,
          presentation: { type: "REDIRECT", returnUrl: return_url }
        }, idempotency_key:, headers:))
      end

      def checkout(id) = to_checkout(@client.get("/agentic/checkouts/#{id}"))

      private

      def to_quote(raw)
        b = raw.fetch("amountBreakdown")
        Quote.new(
          id: raw.fetch("id"),
          total: Money.from_api(b.fetch("finalAmount")),
          subtotal: Money.from_api(b.fetch("itemsSubtotal")),
          shipping: b["shipping"] ? Money.from_api(b["shipping"]) : Money.zero,
          tax: b.dig("tax", "amount") ? Money.from_api(b.dig("tax", "amount")) : Money.zero,
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
