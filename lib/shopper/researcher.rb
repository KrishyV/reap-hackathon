require_relative "money"
require_relative "basket"

module Shopper
  # Plans needs with the LLM, searches Reap's merchant catalogs for each one,
  # ranks real results, and fits a basket to the budget.
  class Researcher
    def initialize(planner:, agentic:, sleeper: ->(s) { sleep(s) })
      @planner = planner
      @agentic = agentic
      @sleeper = sleeper
    end

    def propose(goal:, budget:, log: ->(_) {})
      needs = @planner.plan(goal, budget)
      raise "The agent could not work out what to buy for that goal" if needs.empty?
      log.("Plan: #{needs.map { |n| "#{n[:name]} (P#{n[:priority]})" }.join(', ')}")

      candidates = search_all(needs, budget, log)
      rankings = @planner.rank(goal, budget, needs, candidates.reject { |_, v| v.empty? })
      log.("Compared #{candidates.values.sum(&:size)} products across #{needs.size} needs")

      top_ids = rankings.values.flat_map { |r| r[:ids] }.uniq
      variants = @agentic.details(top_ids).each_with_object({}) do |p, acc|
        v = p["defaultVariant"]
        next unless v && v["available"] && v["price"]
        acc[p["id"]] = { variant_id: v["id"], price: Money.from_api(v["price"]), merchant: p.dig("merchant", "name"), name: p["name"], image: p.dig("media", 0, "url") }
      end

      search_index = candidates.values.flatten.to_h { |c| [c["id"], c] }
      items = needs.map do |n|
        ranking = rankings[n[:key]] || { ids: [], reason: "" }
        options = ranking[:ids].each_with_index.filter_map do |pid, i|
          v = variants[pid] or next
          hit = search_index[pid] || {}
          Option.new(product_id: pid, variant_id: v[:variant_id], name: v[:name] || hit["name"],
                     merchant: v[:merchant] || hit["merchant"] || "Unknown merchant",
                     unit_price: v[:price], image_url: hit["image"] || v[:image],
                     reason: i.zero? ? ranking[:reason] : "Alternative option")
        end
        Item.new(key: n[:key], name: n[:name], priority: n[:priority], quantity: n[:quantity], options:, why: n[:why])
      end

      result = Basket.fit(items, budget)
      log.("Proposed basket: #{result.picks.size} item(s), #{result.total} of #{budget} across #{result.by_merchant.size} merchant(s)")
      [items, result]
    end

    private

    SEARCH_CONCURRENCY = 2
    SEARCH_ATTEMPTS = 3

    # Reap's sandbox sheds load with 503s, so search a couple at a time and retry with backoff.
    def search_all(needs, budget, log)
      queue = Queue.new
      needs.each { |n| queue << n }
      results = {}
      lock = Mutex.new
      workers = Array.new([SEARCH_CONCURRENCY, needs.size].min) do
        Thread.new do
          while (n = (queue.pop(true) rescue nil))
            found = search_one(n, budget, log)
            lock.synchronize { results[n[:key]] = found }
          end
        end
      end
      workers.each(&:join)
      needs.to_h { |n| [n[:key], results.fetch(n[:key], [])] }
    end

    def search_one(need, budget, log)
      attempt = 0
      begin
        attempt += 1
        @agentic.search(need[:query], max_price: budget).filter_map { |p| simplify(p) }
      rescue StandardError => e
        if attempt < SEARCH_ATTEMPTS
          @sleeper.call(1.5 * attempt)
          retry
        end
        log.("Search failed for #{need[:name]}: #{e.message}")
        []
      end
    end

    def simplify(p)
      return nil unless p["available"] != false && p["id"]
      price = p.dig("previewVariant", "price") || p.dig("priceRange", "min")
      return nil unless price
      { "id" => p["id"], "name" => p["name"], "merchant" => p.dig("merchant", "name"),
        "price" => Money.from_api(price).to_s, "image" => p["imageUrl"] }
    end
  end
end
