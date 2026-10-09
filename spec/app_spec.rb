require "rack/test"
require "dotenv"

# Keep the suite hermetic: never read the developer's .env.
Dotenv.singleton_class.define_method(:load) { |*_args, **_kw| {} }
require_relative "../app"

RSpec.describe ShopperApp do
  include Rack::Test::Methods

  ENV_KEYS = %w[REAP_ENROLLMENT_ID REAP_WEBHOOK_SECRET].freeze

  def app = ShopperApp

  let(:items) do
    [Shopper::Item.new(key: "n1", name: "Tent", priority: 1, quantity: 1, why: "shelter",
                       options: [Fakes.option(merchant: "Acme", cents: 5_000, id: "tent-a"), Fakes.option(merchant: "Acme", cents: 3_000, id: "tent-b")]),
     Shopper::Item.new(key: "n2", name: "Lamp", priority: 3, quantity: 2, why: "light",
                       options: [Fakes.option(merchant: "Bolt", cents: 1_000, id: "lamp-a")])]
  end
  let(:ledger) { Fakes::Ledger.new }
  let(:cards) { Fakes::Cards.new(ledger:) }
  let(:agentic) { Fakes::Agentic.new(ledger:, prices: Fakes.prices_for(items)) }
  let(:researcher) { Fakes::Researcher.new(items) }
  let(:store_dir) { File.join(SPEC_TMP_ROOT, "store-#{SecureRandom.hex(4)}") }

  around do |example|
    saved = ENV_KEYS.to_h { [_1, ENV[_1]] }
    ENV_KEYS.each { ENV.delete(_1) }
    example.run
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    FileUtils.rm_rf(store_dir)
  end

  before do
    ShopperApp.set :worker, ShopperApp::InlineWorker
    ShopperApp.set :deps, { researcher:, cards:, agentic: }
    ShopperApp.set :store, Shopper::Store.new(store_dir)
  end

  def create_run(goal: "camping for two", budget: "100")
    post("/runs", goal:, budget:)
    expect(last_response.status).to eq(302)
    last_response.headers["Location"][%r{/runs/(\h+)\z}, 1]
  end

  def run_json(id)
    get "/runs/#{id}.json"
    expect(last_response.status).to eq(200)
    JSON.parse(last_response.body)
  end

  let(:checkout_params) do
    { keep: %w[n1 n2], option_n1: "tent-b", first_name: "Ada", last_name: "Lovelace", email: "ada@example.com",
      phone: "+1 (415) 555-0123", address_line1: "1 Main St", city: "San Francisco", postal_code: "94105", country: "us" }
  end

  it "serves the home page" do
    get "/"
    expect(last_response.status).to eq(200)
  end

  describe "POST /runs validation" do
    it "rejects an empty or overly long goal" do
      ["", "   ", "x" * 501].each do |goal|
        post "/runs", goal:, budget: "100"
        expect(last_response.status).to eq(422)
      end
      expect(researcher.calls).to be_empty
    end

    it "rejects bad budgets" do
      ["", "abc", "-5", "1.999", "0.50", "5000.01", "1e3"].each do |budget|
        post "/runs", goal: "tent", budget: budget
        expect(last_response.status).to eq(422), "budget #{budget.inspect} gave #{last_response.status}"
      end
      expect(researcher.calls).to be_empty
    end
  end

  it "plans a run to awaiting_review and exposes the basket as JSON" do
    id = create_run
    data = run_json(id)
    expect(data["status"]).to eq("awaiting_review")
    expect(data["budget"]).to eq("$100.00")
    expect(data["basket"]["picks"].map { _1["key"] }).to eq(%w[n1 n2])
    expect(data["basket"]["total"]).to eq("$70.00")
    expect(data["basket"]["picks"].first["alternatives"].map { _1["product_id"] }).to eq(["tent-b"])
    expect(researcher.calls).to eq([{ goal: "camping for two", budget: usd(10_000), ship_country: "US" }])

    get "/runs/#{id}"
    expect(last_response.status).to eq(200)
  end

  it "marks the run failed when research raises" do
    def researcher.propose(**) = raise("LLM unavailable")
    data = run_json(create_run)
    expect(data["status"]).to eq("failed")
    expect(data["error"]).to eq("LLM unavailable")
  end

  it "returns 404 for unknown runs" do
    get "/runs/nope.json"
    expect(last_response.status).to eq(404)
  end

  describe "card setup" do
    def state = ShopperApp.settings.store.state

    it "starts an enrollment under one stable owner and shows the link with a QR code" do
      post "/setup/enroll", email: "ada@example.com"
      expect(last_response.status).to eq(302)
      post "/setup/enroll", email: "ada@example.com"
      owners = ledger.of(:enrollment).map { _1[:owner_id] }
      expect(owners.uniq.size).to eq(1)
      expect(owners.first).to eq(state["owner_id"])

      get "/setup"
      expect(last_response.body).to include("Add card on Reap", "https://collect.example/?session=#{state['enrollment_id']}", "456789")
      get "/setup/qr.svg"
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to include("image/svg+xml")
      expect(last_response.body).to include("<svg")
    end

    it "falls back to the saved profile email" do
      post "/setup/enroll"
      expect(last_response.status).to eq(422)
      ShopperApp.settings.store.save_profile("email" => "ada@example.com")
      post "/setup/enroll"
      expect(last_response.status).to eq(302)
      expect(ledger.of(:enrollment).last[:email]).to eq("ada@example.com")
    end

    it "flips to ACTIVE on the status poll once the card is added" do
      post "/setup/enroll", email: "ada@example.com"
      id = state["enrollment_id"]
      get "/setup/status.json"
      expect(JSON.parse(last_response.body)).to include("status" => "REQUIRES_ACTION", "id" => id)
      agentic.activate!(id, last4: "7797")
      get "/setup/status.json"
      expect(JSON.parse(last_response.body)).to include("status" => "ACTIVE", "last4" => "7797", "active" => true)
      get "/setup/qr.svg"
      expect(last_response.status).to eq(404)
    end

    it "reuses an already-active saved card instead of a fresh pending link" do
      post "/setup/enroll", email: "ada@example.com"
      old = state["enrollment_id"]
      agentic.activate!(old, last4: "1111")
      post "/setup/enroll", email: "ada@example.com"
      expect(state["enrollment_id"]).not_to eq(old)

      get "/setup"
      expect(state["enrollment_id"]).to eq(old)
      expect(last_response.body).to include("Your card is connected", "1111")
      expect(Shopper::Log.recent.map { _1[:event] }).to include("setup.card_adopted")
    end

    it "lets you paste an enrollment ID from elsewhere, and validates it" do
      other = agentic.create_enrollment(owner_id: "someone-else", email: "b@example.com", return_url: "https://x.example")
      agentic.activate!(other["id"], last4: "4242")

      post "/setup/use", enrollment_id: "not-a-uuid"
      expect(last_response.status).to eq(422)
      post "/setup/use", enrollment_id: SecureRandom.uuid
      expect(last_response.status).to eq(422)
      expect(last_response.body).to include("NOT_FOUND")

      post "/setup/use", enrollment_id: other["id"].upcase
      expect(last_response.status).to eq(302)
      expect(state["enrollment_id"]).to eq(other["id"])
      get "/setup"
      expect(last_response.body).to include("4242")
    end

    it "never overrides an enrollment pinned in the environment" do
      pinned = agentic.create_enrollment(owner_id: "x", email: "p@example.com", return_url: "https://x.example")
      ENV["REAP_ENROLLMENT_ID"] = pinned["id"]
      post "/setup/enroll", email: "ada@example.com"
      agentic.activate!(state["enrollment_id"])
      get "/setup"
      expect(last_response.body).to include("REAP_ENROLLMENT_ID")
      get "/setup/status.json"
      expect(JSON.parse(last_response.body)["id"]).to eq(pinned["id"])
    end
  end

  describe "purchase" do
    it "requires an enrollment" do
      id = create_run
      post "/runs/#{id}/purchase", checkout_params
      expect(last_response.status).to eq(409)
      expect(run_json(id)["status"]).to eq("awaiting_review")
    end

    it "validates the shipping details" do
      ENV["REAP_ENROLLMENT_ID"] = "enr_test"
      id = create_run
      post "/runs/#{id}/purchase", checkout_params.merge(phone: "555")
      expect(last_response.status).to eq(422)
      post "/runs/#{id}/purchase", checkout_params.merge(keep: [])
      expect(last_response.status).to eq(422)
      expect(ledger.events).to be_empty
    end

    it "buys the reviewed basket, ends done, and freezes the card" do
      ENV["REAP_ENROLLMENT_ID"] = "enr_test"
      id = create_run
      post "/runs/#{id}/purchase", checkout_params
      expect(last_response.status).to eq(302)

      data = run_json(id)
      expect(data["status"]).to eq("done")
      expect(data["receipt"]).to include("frozen" => true, "spent" => "$50.00", "budget" => "$100.00",
                                         "unspent" => "$50.00", "completed" => 2, "orders" => 2)
      expect(data["card"]["last4"]).to eq("4242")
      expect(data["basket"]["picks"].first["option"]["product_id"]).to eq("tent-b")
      expect(data["orders"].map { _1["merchant"] }).to contain_exactly("Acme", "Bolt")
      expect(cards.frozen_ids).to eq([cards.card.id])
      expect(ledger.of(:checkout).map { _1[:enrollment_id] }).to all(eq("enr_test"))
      expect(ledger.of(:provision).first[:budget]).to eq(usd(10_000))

      history = ShopperApp.settings.store.history
      expect(history.size).to eq(1)
      expect(history.first).not_to have_key("log")

      post "/runs/#{id}/purchase", checkout_params
      expect(last_response.status).to eq(409)
      expect(ledger.of(:provision).size).to eq(1)
    end

    it "fails the run but still freezes the card when checkout blows up" do
      ENV["REAP_ENROLLMENT_ID"] = "enr_test"
      boom = Fakes::Scenario.happy.tap { _1.failure = :quote }
      ShopperApp.set :deps, { researcher:, cards:, agentic: Fakes::Agentic.new(ledger:, scenarios: Hash.new(boom), prices: Fakes.prices_for(items)) }
      id = create_run
      post "/runs/#{id}/purchase", checkout_params
      data = run_json(id)
      expect(data["status"]).to eq("failed")
      expect(cards.frozen_ids).to eq([cards.card.id])
    end
  end

  describe "POST /webhooks/reap" do
    let(:body) { { type: "card.transaction.created", id: "evt_1" }.to_json }

    def deliver(header)
      post "/webhooks/reap", body, { "CONTENT_TYPE" => "application/json", "HTTP_X_REAP_WEBHOOK_SIGNATURE" => header }
    end

    it "returns 401 for a bad signature when a secret is configured" do
      ENV["REAP_WEBHOOK_SECRET"] = "whsec_test"
      deliver(Shopper::WebhookVerifier.sign("wrong-secret", body, Time.now.to_i))
      expect(last_response.status).to eq(401)
      deliver("garbage")
      expect(last_response.status).to eq(401)
      deliver(nil)
      expect(last_response.status).to eq(401)
      expect(ShopperApp.settings.store.events).to be_empty
    end

    it "accepts and stores a correctly signed event" do
      ENV["REAP_WEBHOOK_SECRET"] = "whsec_test"
      deliver(Shopper::WebhookVerifier.sign("whsec_test", body, Time.now.to_i))
      expect(last_response.status).to eq(200)
      expect(ShopperApp.settings.store.events.first).to include("verified" => true, "event" => JSON.parse(body))
    end

    it "stores unverified events when no secret is configured" do
      deliver(nil)
      expect(last_response.status).to eq(200)
      expect(ShopperApp.settings.store.events.first["verified"]).to be(false)
    end
  end
end
