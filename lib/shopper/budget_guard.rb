require_relative "money"

module Shopper
  # Local mirror of the prepaid card's budget. Holds are reserved before a checkout
  # and either captured (order placed) or released (order failed). The invariant
  # spent + held <= budget holds after every operation.
  class BudgetGuard
    class Exceeded < StandardError; end
    class UnknownHold < StandardError; end

    attr_reader :budget, :spent

    def initialize(budget)
      @budget = budget
      @spent = Money.zero(budget.currency)
      @holds = {}
      @mutex = Mutex.new
    end

    def held = Money.sum(@holds.values, budget.currency)
    def remaining = budget - spent - held

    def can_reserve?(amount) = amount <= remaining

    def reserve!(hold_id, amount)
      @mutex.synchronize do
        raise ArgumentError, "duplicate hold #{hold_id}" if @holds.key?(hold_id)
        raise Exceeded, "#{amount} exceeds remaining #{remaining}" unless can_reserve?(amount)
        @holds[hold_id] = amount
      end
    end

    # Capture at most the held amount; a lower final amount releases the difference.
    def capture!(hold_id, final_amount)
      @mutex.synchronize do
        held_amount = @holds.fetch(hold_id) { raise UnknownHold, hold_id.to_s }
        raise Exceeded, "final #{final_amount} exceeds hold #{held_amount}" if final_amount > held_amount
        @holds.delete(hold_id)
        @spent += final_amount
      end
    end

    def release!(hold_id)
      @mutex.synchronize { @holds.delete(hold_id) { raise UnknownHold, hold_id.to_s } }
    end

    def invariant_ok? = spent + held <= budget
  end
end
