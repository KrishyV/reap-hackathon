require "securerandom"
require "time"

module Shopper
  # Card enrollment bookkeeping: one stable owner per install, so every card ever added can be
  # listed and reused instead of re-enrolling. Pure helpers; network calls go through Reap::Agentic.
  module CardSetup
    UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    module_function

    def owner_id(store, inherit: nil)
      id = store.state["owner_id"]
      return id unless id.to_s.empty?

      id = inherit.to_s.start_with?("dumpling-") ? inherit : "dumpling-#{SecureRandom.hex(6)}"
      store.update_state("owner_id" => id)
      Log.info("setup.owner_created", owner_id: id)
      id
    end

    def active?(e) = e.is_a?(Hash) && e["status"] == "ACTIVE"

    # Newest ACTIVE enrollment, or nil.
    def best(items)
      Array(items).select { active?(_1) }.max_by { _1["updatedAt"].to_s }
    end

    def pending_url(e, now: Time.now)
      return nil unless e.is_a?(Hash) && e["status"] == "REQUIRES_ACTION"

      url = e.dig("nextAction", "url")
      expires = e.dig("nextAction", "expiresAt")
      return nil if url.to_s.empty?
      return nil if expires && Time.iso8601(expires) <= now

      url
    rescue ArgumentError
      url
    end

    def summary(e, now: Time.now)
      return { status: "NONE" } unless e.is_a?(Hash)

      pm = e["paymentMethod"] || {}
      url = pending_url(e, now:)
      status = e["status"] == "REQUIRES_ACTION" && url.nil? ? "EXPIRED" : e["status"]
      {
        id: e["id"], status:, active: active?(e),
        last4: pm["last4"], network: pm["network"],
        expiry: (pm["expiryMonth"] && pm["expiryYear"] ? format("%02d/%02d", pm["expiryMonth"].to_i, pm["expiryYear"].to_i % 100) : nil),
        email: e.dig("owner", "email"),
        url:, expires_at: url && e.dig("nextAction", "expiresAt"),
        updated_at: e["updatedAt"]
      }
    end
  end
end
