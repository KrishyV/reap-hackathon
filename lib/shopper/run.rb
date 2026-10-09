require "securerandom"
require_relative "money"
require_relative "basket"

module Shopper
  # One shopping request, from goal to frozen card. Mutated by a worker thread,
  # read by the web UI via #to_h.
  class Run
    STATUSES = %w[planning awaiting_review purchasing done failed].freeze

    attr_reader :id, :goal, :budget, :created_at
    attr_accessor :items, :basket, :card, :receipt

    def initialize(goal:, budget:)
      @id = SecureRandom.hex(6)
      @goal = goal
      @budget = budget
      @status = "planning"
      @log = []
      @orders = {}
      @created_at = Time.now
      @mutex = Mutex.new
    end

    def status = @mutex.synchronize { @status }

    def transition!(to, from: nil)
      raise ArgumentError, "unknown status #{to}" unless STATUSES.include?(to)
      @mutex.synchronize do
        raise "run #{id} is #{@status}, expected #{Array(from).join('/')}" if from && !Array(from).include?(@status)
        @status = to
      end
    end

    def log(msg) = @mutex.synchronize { @log << { at: Time.now.strftime("%H:%M:%S"), msg: } }

    def fail!(error)
      log("Error: #{error}")
      @mutex.synchronize { @status = "failed"; @error = error.to_s }
    end

    def upsert_order(order) = @mutex.synchronize { @orders[order.merchant] = order.to_h_public }

    def to_h
      @mutex.synchronize do
        {
          id:, goal:, budget: budget.to_s, status: @status, error: @error, log: @log.dup,
          basket: basket && basket_h,
          card: card && { id: card.id, last4: card.last4, budget: card.budget.to_s },
          orders: @orders.values,
          receipt: receipt && receipt_h
        }
      end
    end

    private

    def basket_h
      {
        total: basket.total.to_s, remaining: basket.remaining.to_s,
        picks: basket.picks.map do |p|
          { key: p.item.key, need: p.item.name, why: p.item.why, priority: p.item.priority, quantity: p.item.quantity,
            line_total: p.line_total.to_s, option: p.option.to_h_public,
            alternatives: p.item.options.reject { |o| o.equal?(p.option) }.map(&:to_h_public) }
        end,
        drops: basket.drops.map { |d| { need: d.item.name, priority: d.item.priority, reason: d.reason } }
      }
    end

    def receipt_h
      {
        spent: receipt.spent.to_s, budget: receipt.budget.to_s, unspent: (receipt.budget - receipt.spent).to_s,
        frozen: receipt.frozen, anomalies: receipt.anomalies,
        completed: receipt.orders.count { |o| o.status == "COMPLETED" }, orders: receipt.orders.size
      }
    end
  end
end
