RSpec.describe Shopper::Researcher do
  let(:planner) do
    Class.new do
      def plan(_goal, _budget) = [{ key: "n1", name: "Tent", query: "tent", priority: 1, quantity: 1, why: "" },
                                  { key: "n2", name: "Lamp", query: "lamp", priority: 3, quantity: 1, why: "" }]
      def rank(_g, _b, _needs, candidates) = Shopper::Planner.sanitize_rankings({}, candidates)
    end.new
  end

  let(:agentic) do
    Class.new do
      attr_reader :search_calls

      def initialize = (@search_calls = Hash.new(0); @lock = Mutex.new)

      def search(query, max_price:)
        n = @lock.synchronize { @search_calls[query] += 1 }
        raise "503 busy" if query == "tent" && n < 3
        raise "always down" if query == "lamp"
        [{ "id" => "p-#{query}", "name" => query, "merchant" => { "name" => "Acme" }, "previewVariant" => { "price" => { "amount" => 19.99 } } }]
      end

      def details(ids)
        ids.map { |id| { "id" => id, "name" => id, "merchant" => { "name" => "Acme" },
                         "defaultVariant" => { "id" => "v-#{id}", "available" => true, "price" => { "amount" => 19.99, "currency" => "USD" } } } }
      end
    end.new
  end

  it "retries flaky searches with backoff and degrades gracefully when one keeps failing" do
    sleeps = []
    logs = []
    researcher = described_class.new(planner:, agentic:, sleeper: ->(s) { sleeps << s })
    items, basket = researcher.propose(goal: "camp", budget: usd(10_000), log: ->(m) { logs << m })

    expect(agentic.search_calls).to eq("tent" => 3, "lamp" => 3)
    expect(sleeps.sort).to eq([1.5, 1.5, 3.0, 3.0])
    expect(logs.grep(/Search failed for Lamp/).size).to eq(1)
    expect(items.map { _1.options.size }).to eq([1, 0])
    expect(basket.picks.map { _1.option.unit_price }).to eq([usd(1999)])
    expect(basket.drops.map(&:reason)).to eq([:no_available_option])
  end
end
