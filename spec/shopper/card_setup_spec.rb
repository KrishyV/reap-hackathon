require "spec_helper"

RSpec.describe Shopper::CardSetup do
  let(:now) { Time.utc(2026, 10, 9, 10, 0, 0) }

  def enr(id, status, updated: "2026-10-09T09:00:00Z", expires: "2026-10-09T10:10:00Z", last4: nil)
    { "id" => id, "status" => status, "updatedAt" => updated,
      "nextAction" => status == "REQUIRES_ACTION" ? { "url" => "https://collect.example/#{id}", "expiresAt" => expires } : nil,
      "paymentMethod" => last4 && { "last4" => last4, "network" => "VISA", "expiryMonth" => 3, "expiryYear" => 2027 } }
  end

  describe ".best" do
    it "picks the most recently updated ACTIVE enrollment" do
      items = [enr("a", "ACTIVE", updated: "2026-10-01T00:00:00Z"), enr("b", "REQUIRES_ACTION", updated: "2026-10-09T00:00:00Z"),
               enr("c", "ACTIVE", updated: "2026-10-05T00:00:00Z"), enr("d", "REVOKED", updated: "2026-10-08T00:00:00Z")]
      expect(described_class.best(items)["id"]).to eq("c")
    end

    it "returns nil when nothing is ACTIVE" do
      expect(described_class.best([enr("a", "REQUIRES_ACTION"), nil])).to be_nil
      expect(described_class.best(nil)).to be_nil
    end
  end

  describe ".summary" do
    it "exposes the link only while it is unexpired" do
      live = described_class.summary(enr("p", "REQUIRES_ACTION"), now:)
      expect(live).to include(status: "REQUIRES_ACTION", url: "https://collect.example/p", active: false)

      dead = described_class.summary(enr("p", "REQUIRES_ACTION", expires: "2026-10-09T09:59:59Z"), now:)
      expect(dead).to include(status: "EXPIRED", url: nil, expires_at: nil)
    end

    it "describes an active card" do
      s = described_class.summary(enr("a", "ACTIVE", last4: "7797"), now:)
      expect(s).to include(active: true, last4: "7797", network: "VISA", expiry: "03/27", url: nil)
    end

    it "handles a missing enrollment" do
      expect(described_class.summary(nil)).to eq(status: "NONE")
    end
  end

  describe ".owner_id" do
    it "is created once and then stable" do
      store = Shopper::Store.new(File.join(SPEC_TMP_ROOT, "cs-#{SecureRandom.hex(4)}"))
      first = described_class.owner_id(store)
      expect(first).to match(/\Adumpling-\h{12}\z/)
      expect(described_class.owner_id(store)).to eq(first)
      expect(Shopper::Store.new(store.instance_variable_get(:@dir)).state["owner_id"]).to eq(first)
    end

    it "inherits the owner of an existing app enrollment so its cards stay listed" do
      store = Shopper::Store.new(File.join(SPEC_TMP_ROOT, "cs-#{SecureRandom.hex(4)}"))
      expect(described_class.owner_id(store, inherit: "dumpling-27b85556")).to eq("dumpling-27b85556")
      other = Shopper::Store.new(File.join(SPEC_TMP_ROOT, "cs-#{SecureRandom.hex(4)}"))
      expect(described_class.owner_id(other, inherit: "someone-else")).to match(/\Adumpling-\h{12}\z/)
    end
  end
end
