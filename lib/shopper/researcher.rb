require_relative "money"
require_relative "basket"
require_relative "fx"
require_relative "log"

module Shopper
  # Plans needs with the LLM, searches Reap's merchant catalogs for each one,
  # ranks real results, and fits a basket to the budget.
  class Researcher
    def initialize(planner:, agentic:, fx: FX.offline, sleeper: ->(s) { sleep(s) })
      @planner = planner
      @agentic = agentic
      @fx = fx
      @sleeper = sleeper
    end

    # ship_country: ISO-3166 alpha-2 of the delivery address; drives catalog availability.
    def propose(goal:, budget:, ship_country: "US", log: ->(_) {})
      Log.with(component: "researcher") { propose!(goal:, budget:, ship_country:, log:) }
    end

    private

    def propose!(goal:, budget:, ship_country:, log:)
      Log.info("research.start", goal:, budget:, ship_country:)
      needs = Log.time("research.plan", level: :info) { @planner.plan(goal, budget) }
      raise "The agent could not work out what to buy for that goal" if needs.empty?
      log.("Plan: #{needs.map { |n| "#{n[:name]} (P#{n[:priority]})" }.join(', ')}")

      candidates = Log.time("research.search_all", level: :info, needs: needs.size) { search_all(needs, budget, ship_country, log) }
      rankings = Log.time("research.rank", level: :info) { @planner.rank(goal, budget, needs, candidates.reject { |_, v| v.empty? }) }
      log.("Compared #{candidates.values.sum(&:size)} products across #{needs.size} needs")

      top_ids = rankings.values.flat_map { |r| r[:ids] }.uniq
      details = Log.time("research.details", level: :info, ids: top_ids.size) { @agentic.details(top_ids) }
      variants = details.each_with_object({}) do |p, acc|
        v = p["defaultVariant"]
        unless v && v["available"] && v["price"]
          Log.debug("research.variant_unavailable", product_id: p["id"], name: p["name"])
          next
        end
        native = Money.from_api(v["price"])
        begin
          estimate = @fx.estimate(native, to: budget.currency)
        rescue FX::Unavailable => e
          Log.warn("research.fx_unavailable", product_id: p["id"], price: native, error: e.message)
          log.("Skipped #{p['name']}: can't convert #{native.currency} right now")
          next
        end
        if native.currency != budget.currency
          Log.info("research.foreign_price", product_id: p["id"], merchant: p.dig("merchant", "name"), native:, estimate:)
        end
        acc[p["id"]] = { variant_id: v["id"], price: estimate, native:, merchant: p.dig("merchant", "name"),
                         name: p["name"], image: p.dig("media", 0, "url") }
      end
      foreign = variants.values.map { _1[:native].currency }.uniq - [budget.currency]
      log.("International merchants priced in #{foreign.join(', ')}; converted at live rates (+FX fee & buffer)") if foreign.any?

      search_index = candidates.values.flatten.to_h { |c| [c["id"], c] }
      items = needs.map do |n|
        ranking = rankings[n[:key]] || { ids: [], reason: "" }
        options = ranking[:ids].each_with_index.filter_map do |pid, i|
          v = variants[pid] or next
          hit = search_index[pid] || {}
          Option.new(product_id: pid, variant_id: v[:variant_id], name: v[:name] || hit["name"],
                     merchant: v[:merchant] || hit["merchant"] || "Unknown merchant",
                     unit_price: v[:price], original_price: v[:native], image_url: hit["image"] || v[:image],
                     reason: i.zero? ? ranking[:reason] : "Alternative option")
        end
        Item.new(key: n[:key], name: n[:name], priority: n[:priority], quantity: n[:quantity], options:, why: n[:why])
      end

      items.each { |it| Log.debug("research.item", key: it.key, need: it.name, options: it.options.map { |o| "#{o.product_id}@#{o.merchant}:#{o.unit_price}" }) }
      result = Basket.fit(items, budget)
      log.("Proposed basket: #{result.picks.size} item(s), #{result.total} of #{budget} across #{result.by_merchant.size} merchant(s)")
      Log.info("research.done", picks: result.picks.size, drops: result.drops.map { |d| "#{d.item.name}:#{d.reason}" },
                                total: result.total, merchants: result.by_merchant.keys)
      [items, result]
    end

    SEARCH_CONCURRENCY = 2
    SEARCH_ATTEMPTS = 3

    # Reap's sandbox sheds load with 503s, so search a couple at a time and retry with backoff.
    def search_all(needs, budget, ship_country, log)
      queue = Queue.new
      needs.each { |n| queue << n }
      results = {}
      lock = Mutex.new
      workers = Array.new([SEARCH_CONCURRENCY, needs.size].min) do
        Log.thread do
          while (n = (queue.pop(true) rescue nil))
            found = search_one(n, budget, ship_country, log)
            lock.synchronize { results[n[:key]] = found }
          end
        end
      end
      workers.each(&:join)
      needs.to_h { |n| [n[:key], results.fetch(n[:key], [])] }
    end

    def search_one(need, budget, ship_country, log)
      attempt = 0
      begin
        attempt += 1
        raw = Log.time("research.search", need: need[:name], query: need[:query], attempt:) do
          @agentic.search(need[:query], max_price: budget, country: ship_country, currency: budget.currency)
        end
        hits = raw.filter_map { |p| simplify(p, budget) }
        Log.info("research.search_results", need: need[:name], returned: raw.size, usable: hits.size,
                                            currencies: hits.map { _1["currency"] }.tally)
        hits
      rescue StandardError => e
        if attempt < SEARCH_ATTEMPTS
          Log.warn("research.search_retry", need: need[:name], attempt:, error_message: e.message)
          @sleeper.call(1.5 * attempt)
          retry
        end
        Log.error("research.search_failed", need: need[:name], attempts: attempt, error_message: e.message)
        log.("Search failed for #{need[:name]}: #{e.message}")
        []
      end
    end

    # Shown to the LLM ranker: native price plus the budget-currency estimate.
    def simplify(p, budget)
      return nil unless p["available"] != false && p["id"]
      price = p.dig("previewVariant", "price") || p.dig("priceRange", "min")
      return nil unless price
      native = Money.from_api(price)
      shown = native.to_s
      if native.currency != budget.currency
        shown = "#{native} (≈ #{@fx.estimate(native, to: budget.currency)})"
      end
      { "id" => p["id"], "name" => p["name"], "merchant" => p.dig("merchant", "name"),
        "price" => shown, "currency" => native.currency, "image" => p["imageUrl"] }
    rescue FX::Unavailable => e
      Log.warn("research.fx_unavailable", product_id: p["id"], error: e.message)
      nil
    end
  end
end
