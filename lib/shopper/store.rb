require "json"
require "fileutils"
require_relative "log"

module Shopper
  # Tiny JSON-file persistence for the demo: enrollment id, order history, webhook events.
  class Store
    def initialize(dir)
      @dir = dir
      @mutex = Mutex.new
      FileUtils.mkdir_p(dir)
    end

    def state = read("state.json", {})
    def update_state(patch) = @mutex.synchronize { write("state.json", state.merge(patch)) }

    PROFILE_FIELDS = %w[first_name last_name email phone address_line1 city region postal_code country].freeze

    # Saved shipping/contact details so repeat purchases are one tap.
    def profile = state["profile"]
    def save_profile(fields) = update_state("profile" => fields.slice(*PROFILE_FIELDS))

    def history = read("orders.json", [])
    def add_history(entry) = @mutex.synchronize { write("orders.json", [entry] + history) }

    def events = read("webhooks.json", [])
    def add_event(event) = @mutex.synchronize { write("webhooks.json", ([event] + events).first(200)) }

    private

    def read(name, default)
      path = File.join(@dir, name)
      File.exist?(path) ? JSON.parse(File.read(path)) : default
    rescue JSON::ParserError => e
      Log.error("store.corrupt", file: name, error_message: e.message)
      default
    end

    def write(name, data)
      path = File.join(@dir, name)
      tmp = "#{path}.tmp"
      File.write(tmp, JSON.pretty_generate(data))
      File.rename(tmp, path)
      Log.debug("store.write", file: name, entries: data.respond_to?(:size) ? data.size : nil)
      data
    end
  end
end
