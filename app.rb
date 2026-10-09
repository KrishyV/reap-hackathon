require "sinatra/base"
require "json"
require "dotenv"
Dotenv.load(File.expand_path(".env", __dir__))
require_relative "lib/shopper"
Shopper::Log.configure unless Shopper::Log.configured?

# Tags every request with a request id, logs method/path/status/duration and
# carries the id into all log events emitted while handling it.
class RequestLogger
  QUIET = %r{\A/(runs/[^/]+\.json|style\.css|favicon)}

  def initialize(app) = @app = app

  def call(env)
    request_id = env["HTTP_X_REQUEST_ID"].to_s[/\A[\w-]{1,64}\z/] || SecureRandom.hex(6)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Shopper::Log.with(request_id:) do
      status, headers, body = @app.call(env)
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
      path = env["PATH_INFO"]
      level = status >= 500 ? :error : (status >= 400 ? :warn : (path.match?(QUIET) ? :debug : :info))
      Shopper::Log.public_send(level, "http.request", method: env["REQUEST_METHOD"], path:, status:, duration_ms: ms,
                                                       query: env["QUERY_STRING"].to_s.empty? ? nil : env["QUERY_STRING"])
      headers["x-request-id"] = request_id
      [status, headers, body]
    end
  end
end

class ShopperApp < Sinatra::Base
  set :root, __dir__
  set :views, File.join(__dir__, "views")
  set :public_folder, File.join(__dir__, "public")
  set :host_authorization, { permitted_hosts: [] }
  set :show_exceptions, false
  set :raise_errors, false
  use RequestLogger

  MAX_BUDGET = Shopper::Money.parse("5000")

  # Sinatra treats Proc settings as getters, so workers are plain objects responding to #call(&blk).
  module ThreadWorker
    def self.call(&blk) = Shopper::Log.thread(&blk)
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
    set :debug_endpoints, ENV.fetch("DEBUG_ENDPOINTS", "true") == "true"
  end

  error do
    err = env["sinatra.error"]
    Shopper::Log.exception("http.unhandled", err, path: request.path_info)
    halt 500, "Internal error (request #{Shopper::Log.context[:request_id]}). See /debug/logs for details."
  end

  helpers do
    def deps = settings.deps || settings.set(:deps, Shopper.build).deps
    def store = settings.store
    def h(text) = Rack::Utils.escape_html(text.to_s)
    def json(data, status_code = 200) = (status(status_code); content_type(:json); JSON.generate(data))
    def enrollment_id = ENV["REAP_ENROLLMENT_ID"].to_s.empty? ? store.state["enrollment_id"] : ENV["REAP_ENROLLMENT_ID"]
    def find_run(id) = RUNS_LOCK.synchronize { RUNS[id] } || halt(404, "Run not found")
    def profile = store.profile
    def enrolled? = !enrollment_id.to_s.empty?
    def merchants = settings.merchants
  end

  # Curated merchant showcase from an empirical sandbox catalog survey (Reap has no merchant-list endpoint).
  MERCHANTS_FILE = File.join(__dir__, "lib", "shopper", "merchants.json")

  configure do
    set :merchants, (File.exist?(MERCHANTS_FILE) ? JSON.parse(File.read(MERCHANTS_FILE)) : [])
  end

  get "/" do
    @history = store.history.first(5)
    @profile = profile
    @enrolled = enrolled?
    @merchants = merchants
    erb :index
  end

  post "/profile" do
    fields = Shopper::Store::PROFILE_FIELDS.to_h { |f| [f, params[f].to_s.strip] }
    holder_and_address(fields.transform_keys(&:to_sym)) # validates or halts 422
    store.save_profile(fields)
    Shopper::Log.info("profile.saved", country: fields["country"])
    back = params[:return_to].to_s
    redirect(back.start_with?("/") && !back.start_with?("//") ? back : "/")
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

    ship_country = params[:ship_country].to_s.strip.upcase.then { |c| c.empty? ? "US" : c }
    halt 422, "Ship-to country must be a 2-letter code like US, GB or SG" unless ship_country.match?(/\A[A-Z]{2}\z/)

    autopilot = params[:autopilot].to_s == "1"
    run = Shopper::Run.new(goal:, budget:, ship_country:, autopilot:)
    RUNS_LOCK.synchronize { RUNS[run.id] = run }
    Shopper::Log.info("run.created", run_id: run.id, goal:, budget:, ship_country:, autopilot:)
    researcher = deps[:researcher]
    saved = profile
    enrollment = enrollment_id
    # Autopilot needs a valid saved address and an enrolled card; otherwise fall back to review.
    contact = if autopilot && saved && !enrollment.to_s.empty?
                catch(:halt) { holder_and_address(saved.transform_keys(&:to_sym).merge(country: ship_country)) }
              end
    autobuy = contact.is_a?(Array) && contact.first.is_a?(Hash)
    Shopper::Log.info("run.autopilot", run_id: run.id, enabled: autobuy, profile: !saved.nil?, enrolled: !enrollment.to_s.empty?) if autopilot
    settings.worker.call do
      Shopper::Log.with(run_id: run.id, phase: "research") do
        run.log("Thinking about: “#{goal}” with #{budget}, shipping to #{ship_country}")
        items, basket = researcher.propose(goal:, budget:, ship_country:, log: run.method(:log))
        run.items = items
        run.basket = basket
        run.transition!("awaiting_review", from: "planning")
        if autobuy && basket.picks.any?
          run.log("Autopilot: basket fits the budget, buying now")
          run.transition!("purchasing", from: "awaiting_review")
          purchase!(run, basket, *contact, enrollment)
        else
          run.log("Autopilot needs a saved address and a connected card, so please review") if autopilot && !autobuy
          run.log("Review the basket and press Buy")
        end
      rescue StandardError => e
        run.fail!(e)
      end
    end
    redirect "/runs/#{run.id}"
  end

  get "/runs/:id.json" do
    json(find_run(params[:id]).to_h)
  end

  get "/runs/:id" do
    @run = find_run(params[:id])
    @enrollment_id = enrollment_id
    @profile = profile
    erb :run
  end

  post "/runs/:id/purchase" do
    run = find_run(params[:id])
    halt 409, "Run is not awaiting review" unless run.status == "awaiting_review"
    enrollment = enrollment_id
    halt 409, "Set up the payment card first (/setup)" if enrollment.to_s.empty?

    fields = (profile || {}).transform_keys(&:to_sym)
    Shopper::Store::PROFILE_FIELDS.each { |f| fields[f.to_sym] = params[f] unless params[f].to_s.strip.empty? }
    holder, address = holder_and_address(fields)
    store.save_profile(fields.transform_keys(&:to_s).transform_values(&:to_s))
    items = selected_items(run, params)
    halt 422, "Select at least one item" if items.empty?
    basket = Shopper::Basket.fit(items, run.budget)
    halt 422, "Nothing fits in the budget" if basket.picks.empty?

    run.basket = basket
    Shopper::Log.info("run.purchase_requested", run_id: run.id, kept: items.map(&:key), picks: basket.picks.size,
                                                drops: basket.drops.map { |d| "#{d.item.key}:#{d.reason}" }, ship_country: address[:country])
    run.transition!("purchasing", from: "awaiting_review")
    settings.worker.call do
      Shopper::Log.with(run_id: run.id) { purchase!(run, basket, holder, address, enrollment) }
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
    @profile = profile
    if @enrollment_id
      @enrollment = begin
        deps[:agentic].enrollment(@enrollment_id)
      rescue StandardError => e
        Shopper::Log.warn("setup.enrollment_lookup_failed", enrollment_id: @enrollment_id, error_message: e.message)
        nil
      end
    end
    erb :setup
  end

  post "/setup/enroll" do
    email = params[:email].to_s.strip
    halt 422, "Enter a valid email" unless email.match?(/\A[^@\s]+@[^@\s]+\.[a-z]{2,}\z/i)
    e = deps[:agentic].create_enrollment(owner_id: "dumpling-#{SecureRandom.hex(4)}", email:, return_url: settings.return_url)
    Shopper::Log.info("setup.enrollment_started", enrollment_id: e["id"], status: e["status"])
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
        Shopper::Log.warn("webhook.rejected", reason: e.message, bytes: raw.bytesize)
        halt 401, e.message
      end
    end
    event = begin
      JSON.parse(raw)
    rescue JSON::ParserError
      Shopper::Log.warn("webhook.invalid_json", bytes: raw.bytesize)
      halt(400, "invalid JSON")
    end
    Shopper::Log.info("webhook.received", verified: !secret.empty?, type: event.is_a?(Hash) ? event["type"] : nil,
                                          event_id: event.is_a?(Hash) ? event["id"] : nil)
    Shopper::Log.debug("webhook.payload", payload: event)
    store.add_event({ "received_at" => Time.now.iso8601, "verified" => !secret.empty?, "event" => event })
    json(ok: true)
  end

  get "/webhooks" do
    json(store.events.first(50))
  end

  # ---- Introspection (localhost only; disable with DEBUG_ENDPOINTS=false) ----

  before "/debug*" do
    halt 404 unless settings.debug_endpoints
    halt 403, "debug endpoints are localhost-only" unless %w[127.0.0.1 ::1].include?(request.ip)
  end

  get "/debug" do
    json(endpoints: {
           "/debug/logs" => "?run_id=&request_id=&level=debug|info|warn|error&event=prefix&since=seq&limit=",
           "/debug/runs" => "all in-memory runs", "/debug/runs/:id" => "run state + its full event trace",
           "/debug/config" => "non-secret configuration", "/debug/fx" => "?currencies=GBP,EUR&amount=100"
         })
  end

  get "/debug/logs" do
    json(Shopper::Log.recent(run_id: params[:run_id], request_id: params[:request_id], level: params[:level],
                             event: params[:event], since_seq: params[:since], limit: params.fetch(:limit, 500)))
  end

  get "/debug/runs" do
    runs = RUNS_LOCK.synchronize { RUNS.values }
    json(runs.sort_by(&:created_at).reverse.map do |r|
      h = r.to_h
      { id: r.id, goal: r.goal, budget: h[:budget], status: h[:status], error: h[:error], created_at: r.created_at.iso8601,
        orders: h[:orders].map { |o| [o[:merchant], o[:status]] }, events: Shopper::Log.recent(run_id: r.id, limit: 5000).size }
    end)
  end

  get "/debug/runs/:id" do
    run = find_run(params[:id])
    events = Shopper::Log.recent(run_id: run.id, level: params[:level], limit: 5000)
    json(run: run.to_h, summary: { events: events.size, by_level: events.map { _1[:level] }.tally,
                                   warnings: events.select { %w[warn error].include?(_1[:level]) } }, trace: events)
  end

  get "/debug/config" do
    json(reap_base_url: ENV.fetch("REAP_BASE_URL", "https://sandbox.api.reap.global"), reap_version: ENV.fetch("REAP_VERSION", "2025-02-14"),
         reap_api_key_set: !ENV["REAP_API_KEY"].to_s.empty?, openai_key_set: !ENV["OPENAI_API_KEY"].to_s.empty?,
         openai_model: ENV.fetch("OPENAI_MODEL", "gpt-4o-mini"), simulate_checkout: deps[:simulate_checkout],
         enrollment_configured: !enrollment_id.to_s.empty?, webhook_secret_set: !ENV["REAP_WEBHOOK_SECRET"].to_s.empty?,
         fx: deps[:fx] && { markup_bps: deps[:fx].markup_bps, buffer_bps: deps[:fx].buffer_bps, cache: deps[:fx].snapshot },
         log: { stderr_level: Shopper::Log::LEVELS.key(Shopper::Log.stderr_level), file_level: Shopper::Log::LEVELS.key(Shopper::Log.file_level),
                file: Shopper::Log.file_path },
         runs_in_memory: RUNS_LOCK.synchronize { RUNS.size })
  end

  get "/debug/fx" do
    fx = deps[:fx] or halt 404, "no FX configured"
    amount = Shopper::Money.parse(params.fetch(:amount, "100")) rescue halt(422, "bad amount")
    currencies = params.fetch(:currencies, "GBP,EUR,JPY,SGD").split(",").map { _1.strip.upcase }.reject(&:empty?).first(20)
    rows = currencies.map do |c|
      native = Shopper::Money.new(amount.cents, c)
      { currency: c, rate_to_usd: fx.rate(from: c, to: "USD").round(6).to_s("F"),
        estimate: fx.estimate(native, to: "USD").to_s, settle: fx.settle(native, to: "USD").to_s, amount: native.to_s }
    rescue Shopper::FX::Unavailable => e
      { currency: c, error: e.message }
    end
    json(markup_bps: fx.markup_bps, buffer_bps: fx.buffer_bps, cache: fx.snapshot, conversions: rows)
  end

  private

  # Runs inside a worker. Issues the card, checks out and records history.
  def purchase!(run, basket, holder, address, enrollment)
    Shopper::Log.with(phase: "purchase") do
      executor = Shopper::Executor.new(cards: deps[:cards], agentic: deps[:agentic], fx: deps.fetch(:fx) { Shopper::FX.offline })
      receipt = executor.run(run_id: run.id, basket:, holder:, address:, enrollment_id: enrollment, return_url: settings.return_url,
                             log: run.method(:log), on_card: ->(c) { run.card = c }, on_order: run.method(:upsert_order))
      run.receipt = receipt
      run.transition!("done", from: "purchasing")
      store.add_history(run.to_h.merge(created_at: run.created_at.iso8601).except(:log))
    rescue StandardError => e
      run.fail!(e)
    end
  end

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
