require_relative "client"
require_relative "../money"
require_relative "../log"

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
        Log.info("card.user_created", user_id: user["id"], external_id: "run-#{run_id}")
        log.("Created cardholder #{user['id'][0, 8]}…")

        Log.time("card.kyc", level: :info, user_id: user["id"]) { approve_kyc!(user["id"], log) }

        account = @client.post("/accounts", { ownerId: user["id"] }, idempotency_key: key.("account"))
        Log.info("card.account_created", account_id: account["id"])
        card = @client.post("/cards", { userId: user["id"], accountId: account["id"], type: "VIRTUAL" }, idempotency_key: key.("card"))
        Log.info("card.issued", card_id: card["id"], last4: card["last4"], status: card["status"])
        log.("Issued virtual card •••• #{card['last4']}")

        @client.post("/postings", {
          accountId: account["id"], type: "DEPOSIT",
          entries: [{ virtualAssetId: usd_asset_id, amount: budget.to_decimal_string }]
        }, idempotency_key: key.("fund"))
        Log.info("card.funded", account_id: account["id"], amount: budget)
        log.("Loaded exactly #{budget} onto the card")

        apply_policies!(card["id"], budget, max_orders, key)
        Log.info("card.policies_applied", card_id: card["id"], spend_cap: budget, max_orders:, blocked_mccs: BLOCKED_MCCS)
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
        unless tx["status"] == "PENDING"
          Log.warn("card.hold_declined", card_id:, amount:, merchant:, status: tx["status"],
                                         decline_code: tx.dig("declineReason", "code"), decline_message: tx.dig("declineReason", "message"))
          raise Declined, tx.dig("declineReason", "code") || tx["status"]
        end
        Log.info("card.hold_placed", card_id:, amount:, merchant:, transaction_id: tx["id"])
        Hold.new(transaction_id: tx["id"], amount:)
      end

      def capture!(card_id:, hold:, amount:, idempotency_key:)
        r = @client.post("/simulation/card-transactions/clearing",
                         { cardId: card_id, transactionId: hold.transaction_id, amount: amount.to_api_number }, idempotency_key:)
        Log.info("card.hold_captured", card_id:, transaction_id: hold.transaction_id, held: hold.amount, captured: amount)
        r
      end

      def release!(card_id:, hold:, idempotency_key:)
        r = @client.post("/simulation/card-transactions/reversal",
                         { cardId: card_id, transactionId: hold.transaction_id, amount: hold.amount.to_api_number }, idempotency_key:)
        Log.info("card.hold_released", card_id:, transaction_id: hold.transaction_id, amount: hold.amount)
        r
      end

      def freeze!(card_id)
        r = @client.post("/cards/#{card_id}/freeze", {})
        Log.info("card.frozen", card_id:, status: r.is_a?(Hash) ? r["status"] : nil)
        r
      end

      def reveal_url(card_id)
        url = @client.post("/cards/#{card_id}/reveal", {})["revealUrl"]
        Log.info("card.reveal_requested", card_id:, url:)
        url
      end

      # The account's effective FX markup in basis points (account override or program default).
      def fx_markup_bps(account_id)
        items = @client.get("/fees/effective?accountId=#{account_id}").fetch("items", [])
        fee = items.find { |f| f["type"] == "FX_MARKUP" }
        bps = fee&.dig("value", "bps")
        Log.info("card.fx_markup", account_id:, bps:, scope: fee&.dig("source", "scope", "type"))
        bps&.to_i
      rescue Error => e
        Log.warn("card.fx_markup_unavailable", account_id:, error_message: e.message)
        nil
      end

      def balance(account_id) = Money.from_api({ "amount" => @client.get("/accounts/#{account_id}/balance")["availableBalance"], "currency" => "USD" })

      private

      def apply_policies!(card_id, budget, max_orders, key)
        policies_for(card_id, budget, max_orders).each do |policy|
          r = @client.post("/policies", policy, idempotency_key: key.("policy-#{policy[:type]}"))
          Log.debug("card.policy", card_id:, type: policy[:type], policy_id: r.is_a?(Hash) ? r["id"] : nil, config: policy[:config])
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
              Log.debug("card.kyc_nudge_ignored", user_id:, code: e.code)
            end
            next_nudge = Time.now + 10
          end
          status = @client.get("/users/#{user_id}").dig("application", "status")
          Log.debug("card.kyc_poll", user_id:, status:)
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
