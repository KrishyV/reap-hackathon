require_relative "money"

module Shopper
  # A purchasable choice for an item. `variant_id` is what Reap quotes accept.
  Option = Struct.new(:product_id, :variant_id, :name, :merchant, :unit_price, :image_url, :reason, keyword_init: true) do
    def to_h_public
      { product_id:, variant_id:, name:, merchant:, unit_price: unit_price.to_s, image_url:, reason: }
    end
  end

  # A need from the plan. Lower `priority` number = more important (1 = essential).
  # `options` are ordered by the agent's preference, best first.
  Item = Struct.new(:key, :name, :priority, :quantity, :options, :why, keyword_init: true)

  Pick = Struct.new(:item, :option, keyword_init: true) do
    def line_total = option.unit_price * item.quantity
    def merchant = option.merchant
  end

  Drop = Struct.new(:item, :reason, keyword_init: true)

  # Chooses one option per item so the basket total never exceeds the budget.
  # Over budget: first downgrade the least important items to cheaper options,
  # then drop the least important items, then refill dropped items that fit on
  # their own (most important first), then upgrade back where room allows.
  module Basket
    Result = Struct.new(:picks, :drops, :budget, keyword_init: true) do
      def total = Money.sum(picks.map(&:line_total), budget.currency)
      def remaining = budget - total
      def by_merchant = picks.group_by(&:merchant)
    end

    module_function

    def fit(items, budget)
      drops = []
      chosen = {}
      items.each do |item|
        if item.options.nil? || item.options.empty? || item.quantity.to_i < 1
          drops << Drop.new(item:, reason: :no_available_option)
        else
          chosen[item.key] = [item, 0]
        end
      end

      total = ->(set) { set.values.sum { |it, idx| it.options[idx].unit_price.cents * it.quantity } }

      while total.(chosen) > budget.cents
        swap = cheaper_swap(chosen)
        if swap
          key, idx = swap
          chosen[key] = [chosen[key][0], idx]
        else
          victim_key = least_important_key(chosen)
          drops << Drop.new(item: chosen.delete(victim_key)[0], reason: :over_budget)
        end
      end

      refill!(chosen, drops, budget, total)
      upgrade!(chosen, budget, total)

      picks = items.filter_map do |item|
        entry = chosen[item.key]
        entry && Pick.new(item:, option: item.options[entry[1]])
      end
      Result.new(picks:, drops:, budget:)
    end

    # Least important item that still has a strictly cheaper option; swap to the next cheaper one.
    def cheaper_swap(chosen)
      candidates = chosen.filter_map do |key, (item, idx)|
        current = item.options[idx].unit_price.cents
        cheaper = item.options.each_with_index
                      .select { |opt, _| opt.unit_price.cents < current }
                      .max_by { |opt, i| [opt.unit_price.cents, -i] }
        cheaper && [key, item, cheaper[1], current]
      end
      return nil if candidates.empty?
      key, _item, idx, = candidates.max_by { |k, item, _i, current| [item.priority, current, k.to_s] }
      [key, idx]
    end

    def least_important_key(chosen)
      chosen.max_by { |key, (item, idx)| [item.priority, item.options[idx].unit_price.cents * item.quantity, key.to_s] }[0]
    end

    # Dropping is importance-ordered, which can leave money unused, e.g. an unaffordable
    # essential dropped after a cheap extra. Re-add dropped items that fit at their cheapest option.
    def refill!(chosen, drops, budget, total)
      drops.select { |d| d.reason == :over_budget }
           .sort_by { |d| [d.item.priority, d.item.key.to_s] }
           .each do |drop|
        item = drop.item
        idx = item.options.each_with_index.min_by { |opt, i| [opt.unit_price.cents, i] }[1]
        trial = chosen.merge(item.key => [item, idx])
        next unless total.(trial) <= budget.cents
        chosen[item.key] = [item, idx]
        drops.delete(drop)
      end
    end

    # Most important items first: move to the most preferred option that still fits.
    def upgrade!(chosen, budget, total)
      chosen.keys.sort_by { |k| [chosen[k][0].priority, k.to_s] }.each do |key|
        item, idx = chosen[key]
        (0...idx).each do |better|
          trial = chosen.merge(key => [item, better])
          if total.(trial) <= budget.cents
            chosen[key] = [item, better]
            break
          end
        end
      end
    end
  end
end
