require "stringio"
require "tmpdir"

RSpec.describe Shopper::Log do
  L = described_class

  describe "payload fidelity (sandbox: nothing is redacted)" do
    it "logs field values verbatim, including nested ones" do
      payload = { "email" => "ada@example.com", "phone" => "+6591234567", "card" => { "pan" => "4111111111111111" } }
      expect(L.info("t.raw", body: payload)[:body]).to eq(payload)
    end

    it "truncates huge strings, in messages and fields" do
      e = L.info("t.big", "y" * 5_000, blob: "x" * 5_000)
      expect(e[:msg].length).to be < 2_100
      expect(e[:blob].length).to be < 2_100
    end
  end

  describe "context" do
    it "merges thread-local context into events and restores it after the block" do
      L.with(run_id: "r1") do
        L.with(merchant: "Acme") { L.info("t.inner") }
        L.info("t.outer")
      end
      L.info("t.after")
      inner, outer, after = L.recent(event: "t.")
      expect(inner).to include(run_id: "r1", merchant: "Acme")
      expect(outer).to include(run_id: "r1")
      expect(outer).not_to have_key(:merchant)
      expect(after).not_to have_key(:run_id)
    end

    it "carries context into threads started with Log.thread" do
      L.with(run_id: "r2", request_id: "q9") { L.thread(phase: "bg") { L.info("t.thread") }.join }
      expect(L.recent(event: "t.thread").last).to include(run_id: "r2", request_id: "q9", phase: "bg")
    end
  end

  describe "ring buffer" do
    it "filters by run, level, event prefix and sequence" do
      L.with(run_id: "a") { L.debug("x.one"); L.warn("x.two") }
      L.with(run_id: "b") { L.error("y.three") }
      expect(L.recent(run_id: "a").map { _1[:event] }).to eq(%w[x.one x.two])
      expect(L.recent(level: "warn").map { _1[:event] }).to eq(%w[x.two y.three])
      expect(L.recent(event: "y.").size).to eq(1)
      first = L.recent.first[:seq]
      expect(L.recent(since_seq: first).map { _1[:event] }).to eq(%w[x.two y.three])
      expect(L.recent(limit: 1).map { _1[:event] }).to eq(%w[y.three])
    end
  end

  describe ".time" do
    it "records duration and success" do
      expect(L.time("t.ok", level: :info) { 7 }).to eq(7)
      expect(L.recent(event: "t.ok").last).to include(ok: true, duration_ms: a_kind_of(Numeric))
    end

    it "logs failures and re-raises" do
      expect { L.time("t.boom") { raise ArgumentError, "nope" } }.to raise_error(ArgumentError)
      expect(L.recent(event: "t.boom").last).to include(ok: false, error: "ArgumentError")
    end
  end

  describe "sinks" do
    after { L.configure(level: "error", file_level: "debug", file: nil, io: nil) }

    it "writes parseable JSON lines to the file and honours the stderr level" do
      Dir.mktmpdir do |dir|
        io = StringIO.new
        path = File.join(dir, "log", "t.jsonl")
        L.configure(level: "warn", file_level: "debug", file: path, io:)
        L.debug("s.debug", amount: Shopper::Money.new(123, "GBP"))
        L.warn("s.warn")
        lines = File.readlines(path).map { JSON.parse(_1) }
        expect(lines.map { _1["event"] }).to eq(%w[s.debug s.warn])
        expect(lines.first["amount"]).to eq("£1.23").or eq("GBP 1.23")
        expect(io.string).to include("s.warn")
        expect(io.string).not_to include("s.debug")
      end
    end

    it "never raises even when a sink is broken" do
      broken = Object.new.tap { |o| def o.puts(*) = raise(IOError, "closed") }
      L.configure(level: "debug", file: nil, io: broken)
      expect { L.info("s.broken") }.not_to raise_error
    end
  end

  describe "Reap client instrumentation" do
    it "logs every call with request and response bodies, status, timing and the Reap request id" do
      client = Shopper::Reap::Client.new(api_key: "sandbox-key", base_url: "https://sandbox.api.reap.global", version: "2025-02-14")
      stub_request(:post, "https://sandbox.api.reap.global/cards").to_return(
        status: 200, body: { id: "c1", last4: "4242" }.to_json, headers: { "x-request-id" => "rq1" }
      )
      client.post("/cards", { name: "x" }, idempotency_key: "idem-123")
      events = L.recent(event: "reap.")
      expect(events.map { _1[:event] }).to include("reap.request", "reap.response", "reap.response_body")
      expect(events.find { _1[:event] == "reap.response" }).to include(status: 200, duration_ms: a_kind_of(Numeric))
      expect(JSON.generate(events)).to include("rq1", "4242")
    end
  end
end
