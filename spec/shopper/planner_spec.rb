RSpec.describe Shopper::Planner do
  let(:scalar) do
    G.one_of(G.nil, G.boolean, G.integer, G.choose(-1_000_000_000..1_000_000_000), G.real_float,
             G.printable_string, G.constant("2"), G.constant(" 3 "), G.constant(1e400), G.constant(-1e400))
  end
  let(:json) do
    G.tree(scalar) { |sub| G.one_of(G.array(sub, max: 3), G.hash_of(G.printable_ascii_string, sub, max: 3)) }
  end

  describe ".sanitize_plan" do
    let(:hostile_item) do
      G.one_of(
        json,
        G.fixed_hash("name" => json, "query" => json, "priority" => json, "quantity" => json, "why" => json),
        G.fixed_hash("name" => G.printable_string(empty: false), "query" => G.printable_string(empty: false),
                     "priority" => scalar, "quantity" => scalar, "why" => scalar)
      )
    end
    let(:raw_plan) { G.one_of(json, G.fixed_hash("items" => G.one_of(json, list_of(hostile_item, 0, 15)))) }

    it "always yields at most MAX_ITEMS well-formed needs" do
      forall(raw_plan, runs: 400) do |raw|
        needs = described_class.sanitize_plan(raw)
        expect(needs).to be_an(Array)
        expect(needs.size).to be <= described_class::MAX_ITEMS
        expect(needs.map { _1[:key] }.uniq.size).to eq(needs.size)
        needs.each do |n|
          expect(n[:priority]).to be_an(Integer).and(be_between(1, 3))
          expect(n[:quantity]).to be_an(Integer).and(be_between(1, 5))
          expect(n[:name]).to be_a(String).and(satisfy { |s| !s.empty? && s.length <= 80 })
          expect(n[:query]).to be_a(String).and(satisfy { |s| !s.empty? && s.length <= 120 })
          expect(n[:why].length).to be <= 200
        end
      end
    end

    it "keeps well-formed values" do
      raw = { "items" => [{ "name" => "Tent", "query" => "2 person tent", "priority" => 1, "quantity" => 2, "why" => "shelter" },
                          { "name" => "Lamp", "query" => "lantern", "priority" => "9", "quantity" => 2.9 }] }
      expect(described_class.sanitize_plan(raw)).to eq([
        { key: "n1", name: "Tent", query: "2 person tent", priority: 1, quantity: 2, why: "shelter" },
        { key: "n2", name: "Lamp", query: "lantern", priority: 3, quantity: 2, why: "" }
      ])
    end
  end

  describe ".sanitize_rankings" do
    let(:id_gen) { G.one_of(*%w[p1 p2 p3 p4 p5 p6 ghost P1 p1\ ].map { G.constant(_1) }) }
    let(:candidates_gen) do
      G.hash_of(G.one_of(*%w[n1 n2 n3].map { G.constant(_1) }),
                list_of(G.one_of(*%w[p1 p2 p3 p4 p5 p6].map { G.constant(_1) }), 1, 6).map { |ids| ids.uniq.map { { "id" => _1 } } },
                max: 4)
    end
    let(:ranking) do
      G.one_of(json, G.fixed_hash("key" => G.one_of(G.constant("n1"), G.constant("n2"), G.constant("nX"), json),
                                  "product_ids" => G.one_of(json, list_of(id_gen, 0, 8)),
                                  "reason" => json))
    end
    let(:raw_gen) { G.one_of(json, G.fixed_hash("rankings" => G.one_of(json, list_of(ranking, 0, 6)))) }

    it "never yields hallucinated ids or keys and caps at three ids" do
      forall(raw_gen, candidates_gen, runs: 400) do |raw, candidates|
        out = described_class.sanitize_rankings(raw, candidates)
        expect(out.keys).to match_array(candidates.keys)
        out.each do |key, r|
          allowed = candidates.fetch(key).map { _1["id"] }
          expect(r[:ids]).not_to be_empty
          expect(r[:ids].size).to be <= 3
          expect(r[:ids]).to all(satisfy { |id| allowed.include?(id) })
          expect(r[:ids].uniq).to eq(r[:ids])
          expect(r[:reason]).to be_a(String)
          expect(r[:reason].length).to be <= 200
        end
      end
    end

    it "honours valid LLM rankings and falls back to catalog order" do
      candidates = { "n1" => %w[a b c d].map { { "id" => _1 } }, "n2" => %w[x y].map { { "id" => _1 } } }
      raw = { "rankings" => [{ "key" => "n1", "product_ids" => %w[c ghost a c], "reason" => "best" }] }
      expect(described_class.sanitize_rankings(raw, candidates)).to eq(
        "n1" => { ids: %w[c a], reason: "best" },
        "n2" => { ids: %w[x y], reason: "Top catalog match" }
      )
    end
  end
end
