require "json"
require "fileutils"

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

    def history = read("orders.json", [])
    def add_history(entry) = @mutex.synchronize { write("orders.json", [entry] + history) }

    def events = read("webhooks.json", [])
    def add_event(event) = @mutex.synchronize { write("webhooks.json", ([event] + events).first(200)) }

    private

    def read(name, default)
      path = File.join(@dir, name)
      File.exist?(path) ? JSON.parse(File.read(path)) : default
    rescue JSON::ParserError
      default
    end

    def write(name, data)
      path = File.join(@dir, name)
      tmp = "#{path}.tmp"
      File.write(tmp, JSON.pretty_generate(data))
      File.rename(tmp, path)
      data
    end
  end
end
