require "net/http"
require "json"

module Shopper
  # Thin OpenAI Chat Completions wrapper returning parsed JSON objects.
  class LLM
    class Error < StandardError; end

    def initialize(api_key:, model: "gpt-4o-mini", base_url: "https://api.openai.com/v1")
      raise ArgumentError, "OPENAI_API_KEY missing" if api_key.to_s.empty?
      @api_key = api_key
      @model = model
      @base_url = base_url
    end

    def json(system:, user:)
      uri = URI("#{@base_url}/chat/completions")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 90
      req = Net::HTTP::Post.new(uri)
      req["Authorization"] = "Bearer #{@api_key}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(model: @model, temperature: 0.2, response_format: { type: "json_object" },
                               messages: [{ role: "system", content: system }, { role: "user", content: user }])
      res = http.request(req)
      raise Error, "OpenAI #{res.code}: #{res.body.to_s[0, 300]}" unless res.code.to_i == 200
      JSON.parse(JSON.parse(res.body).dig("choices", 0, "message", "content"))
    rescue JSON::ParserError => e
      raise Error, "OpenAI returned invalid JSON: #{e.message}"
    end
  end

  # Turns a shopping goal into a list of needs, and ranks real catalog results.
  # LLM output is treated as untrusted: shapes are validated and ids must exist.
  class Planner
    MAX_ITEMS = 8

    PLAN_PROMPT = <<~TXT.freeze
      You are a meticulous shopping agent. Break the user's goal into the concrete products
      they need to buy online. Respond with JSON:
      {"items":[{"name":"short human name","query":"search query for an online store",
      "priority":1|2|3,"quantity":integer,"why":"one sentence"}]}
      priority 1 = essential, 2 = strongly recommended, 3 = nice to have.
      At most #{MAX_ITEMS} items. Keep the total realistic for the budget. Only physical products.
    TXT

    RANK_PROMPT = <<~TXT.freeze
      You are a shopping agent comparing real catalog results. For each need, rank up to 3
      candidate product ids from best to worst for the goal, considering suitability for the
      user, quality and price. Use ONLY ids listed under that need. Respond with JSON:
      {"rankings":[{"key":"need key","product_ids":["id",...],"reason":"one sentence for the top pick"}]}
    TXT

    def initialize(llm:)
      @llm = llm
    end

    def plan(goal, budget)
      raw = @llm.json(system: PLAN_PROMPT, user: "Goal: #{goal}\nTotal budget (incl. shipping & tax): #{budget}")
      self.class.sanitize_plan(raw)
    end

    # candidates: { key => [{ "id", "name", "merchant", "price" }] }
    def rank(goal, budget, needs, candidates)
      listing = needs.map do |n|
        rows = candidates.fetch(n[:key], []).map { |c| "  - #{c['id']} | #{c['name']} | #{c['merchant']} | #{c['price']}" }
        "Need #{n[:key]} (#{n[:name]}, priority #{n[:priority]}, qty #{n[:quantity]}):\n#{rows.join("\n")}"
      end.join("\n\n")
      raw = @llm.json(system: RANK_PROMPT, user: "Goal: #{goal}\nBudget: #{budget}\n\n#{listing}")
      self.class.sanitize_rankings(raw, candidates)
    end

    def self.sanitize_plan(raw)
      items = raw.is_a?(Hash) ? Array(raw["items"]) : []
      items.first(MAX_ITEMS).each_with_index.filter_map do |it, i|
        next unless it.is_a?(Hash)
        name = it["name"].to_s.strip[0, 80]
        query = it["query"].to_s.strip[0, 120]
        next if name.empty? || query.empty?
        {
          key: "n#{i + 1}", name:, query:,
          priority: to_int(it["priority"]).clamp(1, 3),
          quantity: to_int(it["quantity"]).clamp(1, 5),
          why: it["why"].to_s.strip[0, 200]
        }
      end
    end

    # LLM JSON may put arrays, objects, booleans or 1e400 (Infinity) where a number belongs.
    def self.to_int(value)
      value.respond_to?(:to_i) ? value.to_i : 0
    rescue FloatDomainError
      0
    end

    # Returns { key => { ids: [...], reason: } }, keeping only ids that were offered for that key.
    # Needs the LLM skipped fall back to catalog order.
    def self.sanitize_rankings(raw, candidates)
      rankings = raw.is_a?(Hash) ? Array(raw["rankings"]) : []
      out = {}
      rankings.each do |r|
        next unless r.is_a?(Hash) && candidates.key?(r["key"])
        allowed = candidates[r["key"]].map { |c| c["id"] }
        ids = Array(r["product_ids"]).map(&:to_s).select { |id| allowed.include?(id) }.uniq.first(3)
        out[r["key"]] = { ids:, reason: r["reason"].to_s[0, 200] } unless ids.empty?
      end
      candidates.each do |key, list|
        out[key] ||= { ids: list.map { |c| c["id"] }.first(3), reason: "Top catalog match" }
      end
      out
    end
  end
end
