require_relative "shopper/log"
require_relative "shopper/money"
require_relative "shopper/fx"
require_relative "shopper/basket"
require_relative "shopper/budget_guard"
require_relative "shopper/reap/client"
require_relative "shopper/reap/prepaid_cards"
require_relative "shopper/reap/agentic"
require_relative "shopper/planner"
require_relative "shopper/researcher"
require_relative "shopper/executor"
require_relative "shopper/webhook_verifier"
require_relative "shopper/store"
require_relative "shopper/run"
require_relative "shopper/card_setup"

module Shopper
  # Wires real dependencies from ENV.
  def self.build(env = ENV)
    client = Reap::Client.new(
      api_key: env.fetch("REAP_API_KEY"),
      base_url: env.fetch("REAP_BASE_URL", "https://sandbox.api.reap.global"),
      version: env.fetch("REAP_VERSION", "2025-02-14")
    )
    simulate = env.fetch("SIMULATE_CHECKOUT", client.sandbox? ? "true" : "false") == "true"
    agentic = Reap::Agentic.new(client:, simulate_checkout: simulate)
    fx = FX.new(markup_bps: Integer(env.fetch("FX_MARKUP_BPS", "150")), buffer_bps: Integer(env.fetch("FX_BUFFER_BPS", "100")),
                ttl: Integer(env.fetch("FX_TTL_SECONDS", "3600")))
    llm = LLM.new(api_key: env.fetch("OPENAI_API_KEY"), model: env.fetch("OPENAI_MODEL", "gpt-4o-mini"))
    Log.info("app.wired", reap_base: client.sandbox? ? "sandbox" : "production", simulate_checkout: simulate,
                          llm_model: env.fetch("OPENAI_MODEL", "gpt-4o-mini"), fx_markup_bps: fx.markup_bps, fx_buffer_bps: fx.buffer_bps)
    {
      client:, agentic:, fx:,
      cards: Reap::PrepaidCards.new(client:),
      researcher: Researcher.new(planner: Planner.new(llm:), agentic:, fx:),
      simulate_checkout: simulate
    }
  end
end
