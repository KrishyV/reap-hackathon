require_relative "client"
require_relative "../money"

module Shopper
  module Reap
    # Issues a single-use, budget-capped prepaid virtual card via the Reap Cards API.
    class PrepaidCards
      Card = Struct.new(:id, :user_id, :account_id, :last4, :budget, keyword_init: true)
      Hold = Struct.new(:transaction_id, :amount, keyword_init: true)

      class Declined < StandardError
        attr_reader :reason
        def initialize(reason) = (@reason = reason; super("card declined: #{reason}"))
      end

      # MCCs blocked on every agent card: gambling, betting, dating, wire/quasi-cash.
      BLOCKED_MCCS = %w[7995 7800 7801 7802 7273 4829 6051].freeze
      HOLD_MCC = "5999" # Miscellaneous retail

      def initialize(client:, sleeper: ->(s) { sleep(s) }, kyc_timeout: 60)
        @client = client
        @sleeper = sleeper
        @kyc_timeout = kyc_timeout
      end

      # run_id scopes idempotency keys so a retried provision never issues a second card.
      def provision(run_id:, budget:, holder:, max_orders:, log: ->(_) {})
        key = ->(step) { Idempotency.key(run_id, "card", step) }

        user = @client.post("/users", {
          externalId: "run-#{run_id}",
          email: holder.fetch(:email),
          phoneNumber: holder[:phone] || random_phone,
          firstName: holder.fetch(:first_name),
          lastName: holder.fetch(:last_name)
        }, idempotency_key: key.("user"))
        log.("Created cardholder #{user['id'][0, 8]}…")

        approve_kyc!(user["id"], log)

        account = @client.post("/accounts", { ownerId: user["id"] }, idempotency_key: key.("account"))
        card = @client.post("/cards", { userId: user["id"], accountId: account["id"], type: "VIRTUAL" }, idempotency_key: key.("card"))
        log.("Issued virtual card •••• #{card['last4']}")

        @client.post("/postings", {
          accountId: account["id"], type: "DEPOSIT",
          entries: [{ virtualAssetId: usd_asset_id, amount: budget.to_decimal_string }]
        }, idempotency_key: key.("fund"))
        log.("Loaded exactly #{budget} onto the card")

        apply_policies!(card["id"], budget, max_orders, key)
        log.("Locked card: lifetime cap #{budget}, max #{max_orders} charge(s), online only, risky MCCs blocked")

        Card.new(id: card["id"], user_id: user["id"], account_id: account["id"], last4: card["last4"], budget:)
      end

      def policies_for(card_id, budget, max_orders)
        scope = { type: "CARD", id: card_id }
        [
          { type: "SPEND_LIMIT", scope:, name: "Agent budget cap",
            config: { window: { type: "CALENDAR", period: "LIFETIME" }, maxAmount: budget.to_api_number } },
          { type: "AUTHORIZATION_COUNT_LIMIT", scope:, name: "One charge per merchant order",
            config: { window: { type: "CALENDAR", period: "LIFETIME" }, maxCount: max_orders } },
          { type: "CHANNEL_RESTRICTION", scope:, name: "Online only", config: { channels: %w[POS ATM] } },
          { type: "MERCHANT_RESTRICTION", scope:, name: "Block risky merchant categories",
            config: { match: { dimension: "MCC", codes: BLOCKED_MCCS } } }
        ]
      end

      # Sandbox bridge: Agentic Payments cannot charge REAP_CARD enrollments yet, so the
      # order total is authorised on the prepaid card first. A decline means no checkout.
      def hold!(card_id:, amount:, merchant:, idempotency_key:)
        tx = @client.post("/simulation/card-transactions/authorization", {
          cardId: card_id, amount: amount.to_api_number, channel: "ECOMMERCE",
          merchant: { name: merchant.to_s[0, 60].then { |m| m.empty? ? "Merchant" : m }, mccCode: HOLD_MCC, country: "US" }
        }, idempotency_key:)
        raise Declined, tx.dig("declineReason", "code") || tx["status"] unless tx["status"] == "PENDING"
        Hold.new(transaction_id: tx["id"], amount:)
      end

      def capture!(card_id:, hold:, amount:, idempotency_key:)
        @client.post("/simulation/card-transactions/clearing",
                     { cardId: card_id, transactionId: hold.transaction_id, amount: amount.to_api_number }, idempotency_key:)
      end

      def release!(card_id:, hold:, idempotency_key:)
        @client.post("/simulation/card-transactions/reversal",
                     { cardId: card_id, transactionId: hold.transaction_id, amount: hold.amount.to_api_number }, idempotency_key:)
      end

      def freeze!(card_id) = @client.post("/cards/#{card_id}/freeze", {})

      def reveal_url(card_id) = @client.post("/cards/#{card_id}/reveal", {})["revealUrl"]

      def balance(account_id) = Money.from_api({ "amount" => @client.get("/accounts/#{account_id}/balance")["availableBalance"], "currency" => "USD" })

      private

      def apply_policies!(card_id, budget, max_orders, key)
        policies_for(card_id, budget, max_orders).each do |policy|
          @client.post("/policies", policy, idempotency_key: key.("policy-#{policy[:type]}"))
        end
      end

      def approve_kyc!(user_id, log)
        deadline = Time.now + @kyc_timeout
        next_nudge = Time.now
        loop do
          if Time.now >= next_nudge
            begin
              @client.post("/simulation/users/#{user_id}/application", { status: "APPROVED" })
            rescue Error => e
              raise unless %w[SIMULATION_INVALID_STATE USER_APPLICATION_FINALIZING].include?(e.code)
            end
            next_nudge = Time.now + 10
          end
          status = @client.get("/users/#{user_id}").dig("application", "status")
          if status == "APPROVED"
            log.("KYC approved (sandbox simulation)")
            return
          end
          raise Error.new(status: 0, code: "KYC_TIMEOUT", message: "KYC not approved (#{status})") if Time.now > deadline
          @sleeper.call(2)
        end
      end

      def usd_asset_id
        @usd_asset_id ||= begin
          existing = @client.get("/virtual-assets")["items"].find { |a| a["symbol"] == "USD" && a["status"] == "ACTIVE" }
          existing&.dig("id") || @client.post("/virtual-assets", { symbol: "USD", name: "US Dollar", decimals: 2, rateSource: "FIXED", rate: 1 },
                                              idempotency_key: Idempotency.key("virtual-asset", "USD"))["id"]
        end
      end

      def random_phone = "+1415#{rand(200..999)}#{rand(1000..9999)}"
    end
  end
end
