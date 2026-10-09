require "sinatra/base"
require "json"
require "dotenv"
Dotenv.load(File.expand_path(".env", __dir__))
require_relative "lib/shopper"

class ShopperApp < Sinatra::Base
  set :root, __dir__
  set :views, File.join(__dir__, "views")
  set :public_folder, File.join(__dir__, "public")
  set :host_authorization, { permitted_hosts: [] }

  MAX_BUDGET = Shopper::Money.parse("5000")

  # Sinatra treats Proc settings as getters, so workers are plain objects responding to #call(&blk).
  module ThreadWorker
    def self.call(&blk) = Thread.new(&blk)
  end

  module InlineWorker
    def self.call = yield
  end
  RUNS = {}
  RUNS_LOCK = Mutex.new

  configure do
    set :deps, nil
    set :store, Shopper::Store.new(File.join(__dir__, "data"))
    set :return_url, ENV.fetch("RETURN_URL", "https://example.com/reap-return")
    set :worker, ThreadWorker
  end

  helpers do
    def deps = settings.deps || settings.set(:deps, Shopper.build).deps
    def store = settings.store
    def h(text) = Rack::Utils.escape_html(text.to_s)
    def json(data, status_code = 200) = (status(status_code); content_type(:json); JSON.generate(data))
    def enrollment_id = ENV["REAP_ENROLLMENT_ID"].to_s.empty? ? store.state["enrollment_id"] : ENV["REAP_ENROLLMENT_ID"]
    def find_run(id) = RUNS_LOCK.synchronize { RUNS[id] } || halt(404, "Run not found")
  end

  get "/" do
    @history = store.history.first(5)
    erb :index
  end

  post "/runs" do
    goal = params[:goal].to_s.strip
    halt 422, "Tell the agent what you want to buy" if goal.empty? || goal.length > 500
    budget = begin
      Shopper::Money.parse(params[:budget])
    rescue ArgumentError
      halt 422, "Budget must be a dollar amount like 150 or 149.99"
    end
    halt 422, "Budget must be between $1 and #{MAX_BUDGET}" if budget.cents < 100 || budget > MAX_BUDGET

    run = Shopper::Run.new(goal:, budget:)
    RUNS_LOCK.synchronize { RUNS[run.id] = run }
    researcher = deps[:researcher]
    settings.worker.call do
      run.log("Thinking about: “#{goal}” with #{budget}")
      items, basket = researcher.propose(goal:, budget:, log: run.method(:log))
      run.items = items
      run.basket = basket
      run.transition!("awaiting_review", from: "planning")
      run.log("Review the basket and press Buy")
    rescue StandardError => e
      run.fail!(e.message)
    end
    redirect "/runs/#{run.id}"
  end

  get "/runs/:id.json" do
    json(find_run(params[:id]).to_h)
  end

  get "/runs/:id" do
    @run = find_run(params[:id])
    @enrollment_id = enrollment_id
    erb :run
  end

  post "/runs/:id/purchase" do
    run = find_run(params[:id])
    halt 409, "Run is not awaiting review" unless run.status == "awaiting_review"
    enrollment = enrollment_id
    halt 409, "Set up the payment card first (/setup)" if enrollment.to_s.empty?

    holder, address = holder_and_address(params)
    items = selected_items(run, params)
    halt 422, "Select at least one item" if items.empty?
    basket = Shopper::Basket.fit(items, run.budget)
    halt 422, "Nothing fits in the budget" if basket.picks.empty?

    run.basket = basket
    run.transition!("purchasing", from: "awaiting_review")
    executor = Shopper::Executor.new(cards: deps[:cards], agentic: deps[:agentic])
    return_url = settings.return_url
    store = self.store
    settings.worker.call do
      receipt = executor.run(run_id: run.id, basket:, holder:, address:, enrollment_id: enrollment, return_url:,
                             log: run.method(:log), on_card: ->(c) { run.card = c }, on_order: run.method(:upsert_order))
      run.receipt = receipt
      run.transition!("done", from: "purchasing")
      store.add_history(run.to_h.merge(created_at: run.created_at.iso8601).except(:log))
    rescue StandardError => e
      run.fail!(e.message)
    end
    redirect "/runs/#{run.id}"
  end

  post "/runs/:id/reveal" do
    run = find_run(params[:id])
    halt 409, "No card yet" unless run.card
    json(url: deps[:cards].reveal_url(run.card.id))
  end

  get "/setup" do
    @enrollment_id = enrollment_id
    @enrollment = (deps[:agentic].enrollment(@enrollment_id) rescue nil) if @enrollment_id
    erb :setup
  end

  post "/setup/enroll" do
    email = params[:email].to_s.strip
    halt 422, "Enter a valid email" unless email.match?(/\A[^@\s]+@[^@\s]+\.[a-z]{2,}\z/i)
    e = deps[:agentic].create_enrollment(owner_id: "dumpling-#{SecureRandom.hex(4)}", email:, return_url: settings.return_url)
    store.update_state("enrollment_id" => e["id"], "enrollment_url" => e.dig("nextAction", "url"))
    redirect "/setup"
  end

  get "/orders" do
    @history = store.history
    erb :orders
  end

  post "/webhooks/reap" do
    request.body.rewind
    raw = request.body.read
    secret = ENV["REAP_WEBHOOK_SECRET"].to_s
    unless secret.empty?
      begin
        Shopper::WebhookVerifier.verify!(secret:, raw_body: raw, header: request.env["HTTP_X_REAP_WEBHOOK_SIGNATURE"])
      rescue Shopper::WebhookVerifier::Invalid => e
        halt 401, e.message
      end
    end
    event = JSON.parse(raw) rescue halt(400, "invalid JSON")
    store.add_event({ "received_at" => Time.now.iso8601, "verified" => !secret.empty?, "event" => event })
    json(ok: true)
  end

  get "/webhooks" do
    json(store.events.first(50))
  end

  private

  def holder_and_address(p)
    first = p[:first_name].to_s.strip
    last = p[:last_name].to_s.strip
    email = p[:email].to_s.strip
    phone = p[:phone].to_s.gsub(/[\s\-()]/, "")
    halt 422, "Name is required" if first.empty? || last.empty?
    halt 422, "Valid email is required" unless email.match?(/\A[^@\s]+@[^@\s]+\.[a-z]{2,}\z/i)
    halt 422, "Phone must be in international format, e.g. +14155550123" unless phone.match?(/\A\+[1-9]\d{6,14}\z/)
    %i[address_line1 city postal_code country].each { |f| halt 422, "#{f.to_s.tr('_', ' ').capitalize} is required" if p[f].to_s.strip.empty? }
    address = {
      firstName: first, lastName: last, phone:,
      addressLine1: p[:address_line1].to_s.strip, city: p[:city].to_s.strip,
      region: p[:region].to_s.strip, postalCode: p[:postal_code].to_s.strip,
      country: p[:country].to_s.strip.upcase[0, 2]
    }
    address.delete(:region) if address[:region].empty?
    [{ first_name: first, last_name: last, email: }, address]
  end

  # Keep only ticked items; the option the user picked moves to the front of its preference list.
  def selected_items(run, p)
    keep = Array(p[:keep])
    (run.items || []).filter_map do |item|
      next unless keep.include?(item.key)
      chosen = p["option_#{item.key}"].to_s
      options = item.options.each_with_index.sort_by { |o, i| [o.product_id == chosen ? 0 : 1, i] }.map(&:first)
      Shopper::Item.new(**item.to_h.merge(options:))
    end
  end
end
