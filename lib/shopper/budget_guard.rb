require_relative "money"
require_relative "log"

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
        unless can_reserve?(amount)
          Log.warn("guard.reserve_refused", hold: hold_id.to_s[0, 12], amount:, remaining:)
          raise Exceeded, "#{amount} exceeds remaining #{remaining}"
        end
        @holds[hold_id] = amount
        Log.info("guard.reserved", hold: hold_id.to_s[0, 12], amount:, spent:, held:, remaining:)
      end
    end

    # Capture at most the held amount; a lower final amount releases the difference.
    def capture!(hold_id, final_amount)
      @mutex.synchronize do
        held_amount = @holds.fetch(hold_id) { raise UnknownHold, hold_id.to_s }
        if final_amount > held_amount
          Log.error("guard.capture_refused", hold: hold_id.to_s[0, 12], final: final_amount, held: held_amount)
          raise Exceeded, "final #{final_amount} exceeds hold #{held_amount}"
        end
        @holds.delete(hold_id)
        @spent += final_amount
        Log.info("guard.captured", hold: hold_id.to_s[0, 12], held: held_amount, captured: final_amount,
                                   released: held_amount - final_amount, spent: @spent, remaining:)
        @spent
      end
    end

    def release!(hold_id)
      @mutex.synchronize do
        amount = @holds.delete(hold_id) { raise UnknownHold, hold_id.to_s }
        Log.info("guard.released", hold: hold_id.to_s[0, 12], amount:, spent:, remaining:)
        amount
      end
    end

    def invariant_ok? = spent + held <= budget
  end
end
