RSpec.describe Shopper::Reap::Client do
  let(:base) { "https://sandbox.api.reap.global" }
  let(:sleeps) { [] }
  let(:client) { described_class.new(api_key: "test-key-not-real", base_url: base, version: "2025-02-14", sleeper: ->(s) { sleeps << s }) }

  it "retries a 503 with the same Idempotency-Key and returns the 200 body" do
    keys = []
    stub_request(:post, "#{base}/cards")
      .with { |req| keys << req.headers["Idempotency-Key"] }
      .to_return({ status: 503, body: '{"error":{"code":"UNAVAILABLE","message":"busy"}}' },
                 { status: 200, body: '{"id":"card_1"}' })

    expect(client.post("/cards", { type: "VIRTUAL" }, idempotency_key: "idem-123")).to eq("id" => "card_1")
    expect(keys).to eq(%w[idem-123 idem-123])
    expect(sleeps.size).to eq(1)
  end

  it "reuses the generated key across retries when none is given" do
    keys = []
    stub_request(:post, "#{base}/x").with { |req| keys << req.headers["Idempotency-Key"] }
                                     .to_return({ status: 502 }, { status: 429 }, { status: 201, body: "{}" })
    client.post("/x")
    expect(keys.size).to eq(3)
    expect(keys.uniq.size).to eq(1)
    expect(keys.first).to match(/\A\h{8}-/)
  end

  it "raises Reap::Error with status and code on a 400 without retrying" do
    stub = stub_request(:post, "#{base}/cards")
           .to_return(status: 400, body: '{"error":{"code":"VALIDATION_ERROR","message":"bad card","detail":"type"}}')
    expect { client.post("/cards", {}) }.to raise_error(Shopper::Reap::Error) { |e|
      expect(e.status).to eq(400)
      expect(e.code).to eq("VALIDATION_ERROR")
      expect(e.detail).to eq("type")
      expect(e.message).to include("bad card")
    }
    expect(stub).to have_been_requested.once
    expect(sleeps).to be_empty
  end

  it "falls back to HTTP_<status> for non-JSON error bodies" do
    stub_request(:get, "#{base}/users/1").to_return(status: 404, body: "not here")
    expect { client.get("/users/1") }.to raise_error(Shopper::Reap::Error) { expect(_1.code).to eq("HTTP_404") }
  end

  it "gives up after max_retries and raises the last error" do
    stub = stub_request(:get, "#{base}/slow").to_return(status: 503, body: '{"code":"DOWN","message":"down"}')
    expect { client.get("/slow") }.to raise_error(Shopper::Reap::Error) { expect(_1.code).to eq("DOWN") }
    expect(stub).to have_been_requested.times(3)
  end

  it "retries network errors then succeeds" do
    stub_request(:get, "#{base}/net").to_timeout.then.to_return(status: 200, body: '{"ok":true}')
    expect(client.get("/net")).to eq("ok" => true)
  end

  it "sends Reap-Version, Accept and JSON content type, and a JSON body" do
    stub = stub_request(:post, "#{base}/policies")
           .with(headers: { "Reap-Version" => "2025-02-14", "Accept" => "application/json", "Content-Type" => "application/json" },
                 body: { type: "SPEND_LIMIT" }.to_json)
           .to_return(status: 200, body: "{}")
    client.post("/policies", { type: "SPEND_LIMIT" })
    expect(stub).to have_been_requested
    expect(a_request(:post, "#{base}/policies").with { |r| r.headers.key?("Authorization") }).to have_been_made
  end

  it "passes extra headers through" do
    stub = stub_request(:post, "#{base}/agentic/checkouts").with(headers: { "X-Simulate-Checkout" => "COMPLETED" }).to_return(status: 200, body: "{}")
    client.post("/agentic/checkouts", {}, headers: { "X-Simulate-Checkout" => "COMPLETED" })
    expect(stub).to have_been_requested
  end

  it "requires an API key and detects the sandbox" do
    expect { described_class.new(api_key: "") }.to raise_error(ArgumentError)
    expect(client.sandbox?).to be(true)
    expect(described_class.new(api_key: "k", base_url: "https://api.reap.global").sandbox?).to be(false)
  end
end
