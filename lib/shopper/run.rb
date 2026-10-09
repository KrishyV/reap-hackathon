require "securerandom"
require_relative "money"
require_relative "basket"
require_relative "log"

module Shopper
  # One shopping request, from goal to frozen card. Mutated by a worker thread,
  # read by the web UI via #to_h.
  class Run
    STATUSES = %w[planning awaiting_review purchasing done failed].freeze

    attr_reader :id, :goal, :budget, :created_at, :ship_country, :autopilot, :items, :basket, :card, :receipt

    # Persistence hook (see RunStore): called after every state change so a server restart doesn't lose the run.
    attr_writer :on_change

    %i[items basket card receipt].each do |attr|
      define_method(:"#{attr}=") { |v| instance_variable_set(:"@#{attr}", v).tap { changed! } }
    end

    def initialize(goal:, budget:, ship_country: "US", autopilot: false)
      @autopilot = autopilot
      @id = SecureRandom.hex(6)
      @goal = goal
      @budget = budget
      @ship_country = ship_country
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
        Log.info("run.transition", run_id: id, from: @status, to:)
        @status = to
      end
      changed!
    end

    def log(msg)
      Log.info("run.log", msg.to_s, run_id: id)
      @mutex.synchronize { @log << { at: Time.now.strftime("%H:%M:%S"), msg: } }
      changed!
    end

    def fail!(error)
      if error.is_a?(Exception)
        Log.exception("run.failed", error, run_id: id, from: status)
      else
        Log.error("run.failed", error.to_s, run_id: id, from: status)
      end
      log("Error: #{error.is_a?(Exception) ? error.message : error}")
      @mutex.synchronize { @status = "failed"; @error = error.is_a?(Exception) ? error.message : error.to_s }
      changed!
    end

    def upsert_order(order)
      @mutex.synchronize { @orders[order.merchant] = order.to_h_public }
      changed!
    end

    # A run restored after a restart lost its worker thread. Review can resume; in-flight work cannot.
    def recover_after_restart!
      case status
      when "planning" then fail!("The server restarted while planning. Please start the request again.")
      when "purchasing" then fail!("The server restarted during checkout. Check Orders before retrying, a charge may have gone through.")
      end
    end

    def marshal_dump = instance_variables.reject { %i[@mutex @on_change].include?(_1) }.to_h { [_1, instance_variable_get(_1)] }

    def marshal_load(ivars)
      ivars.each { |k, v| instance_variable_set(k, v) }
      @mutex = Mutex.new
    end

    def to_h
      @mutex.synchronize do
        {
          id:, goal:, budget: budget.to_s, ship_country:, autopilot:, status: @status, error: @error, log: @log.dup,
          basket: basket && basket_h,
          card: card && { id: card.id, last4: card.last4, budget: card.budget.to_s },
          orders: @orders.values,
          receipt: receipt && receipt_h
        }
      end
    end

    private

    def changed!
      @on_change&.call(self)
    rescue StandardError => e
      Log.warn("run.persist_failed", run_id: id, error_message: e.message)
    end

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
