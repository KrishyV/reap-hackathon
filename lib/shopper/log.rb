require "json"
require "time"
require "securerandom"
require "fileutils"
require_relative "money"

module Shopper
  # Structured, context-aware logging. Unredacted by design: sandbox use only.
  #
  # Every event is a Hash: { ts, level, event, msg?, ...context, ...fields }.
  # Context (run_id, request_id, merchant, ...) is thread-local and flows into
  # worker threads started with Log.thread. Events go to three sinks:
  #   - stderr, human readable, at LOG_LEVEL (default info)
  #   - a JSON-lines file (LOG_FILE, default log/shopper.jsonl) at LOG_FILE_LEVEL (default debug)
  #   - an in-memory ring buffer at the file level, queryable via Log.recent and /debug/logs
  module Log
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }.freeze
    MAX_STRING = 2_000

    @mutex = Mutex.new
    @buffer = []
    @seq = 0

    class << self
      attr_reader :stderr_level, :file_level, :file_path

      def configure(level: ENV.fetch("LOG_LEVEL", "info"), file_level: ENV.fetch("LOG_FILE_LEVEL", "debug"),
                    file: ENV.fetch("LOG_FILE", "log/shopper.jsonl"), io: $stderr, format: ENV.fetch("LOG_FORMAT", "pretty"),
                    buffer_size: Integer(ENV.fetch("LOG_BUFFER", "5000")))
        @mutex.synchronize do
          @stderr_level = parse_level(level)
          @file_level = parse_level(file_level)
          @io = io
          @format = format.to_s
          @buffer_size = buffer_size
          @buffer = []
          @file&.close
          @file = nil
          @file_path = file.to_s.empty? ? nil : file
          if @file_path
            FileUtils.mkdir_p(File.dirname(@file_path))
            @file = File.open(@file_path, "a")
            @file.sync = true
          end
        end
        self
      end

      def configured? = !!(defined?(@format) && @format)

      def debug(event, msg = nil, **fields) = emit(:debug, event, msg, fields)
      def info(event, msg = nil, **fields) = emit(:info, event, msg, fields)
      def warn(event, msg = nil, **fields) = emit(:warn, event, msg, fields)
      def error(event, msg = nil, **fields) = emit(:error, event, msg, fields)

      def enabled?(level) = LEVELS.fetch(level) >= min_level

      # Thread-local context merged into every event logged inside the block.
      def with(**ctx)
        previous = context
        Thread.current[:shopper_log_ctx] = previous.merge(ctx.compact)
        yield
      ensure
        Thread.current[:shopper_log_ctx] = previous
      end

      def context = Thread.current[:shopper_log_ctx] || {}

      # Thread.new that carries the caller's log context into the new thread.
      def thread(**extra, &blk)
        ctx = context.merge(extra)
        Thread.new { with(**ctx, &blk) }
      end

      # Logs "<event>" with duration_ms and outcome; re-raises errors after logging them.
      def time(event, level: :debug, **fields)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = yield
        emit(level, event, nil, fields.merge(ok: true, duration_ms: elapsed_ms(started)))
        result
      rescue StandardError => e
        emit(:error, event, nil, fields.merge(ok: false, duration_ms: elapsed_ms(started), error: e.class.name, error_message: e.message))
        raise
      end

      # Error with class, message and a short backtrace.
      def exception(event, err, level: :error, **fields)
        emit(level, event, err.message, fields.merge(error: err.class.name, backtrace: Array(err.backtrace).first(8)))
      end

      # Newest-last list of buffered events, filtered.
      def recent(run_id: nil, request_id: nil, level: nil, event: nil, since_seq: nil, limit: 500)
        min = level ? parse_level(level) : 0
        list = @mutex.synchronize { @buffer.dup }
        list = list.select do |e|
          (run_id.nil? || e[:run_id] == run_id) &&
            (request_id.nil? || e[:request_id] == request_id) &&
            LEVELS.fetch(e[:level].to_sym) >= min &&
            (event.nil? || e[:event].to_s.start_with?(event)) &&
            (since_seq.nil? || e[:seq] > since_seq.to_i)
        end
        list.last(limit.to_i.clamp(1, 5_000))
      end

      def clear! = @mutex.synchronize { @buffer.clear }

      # Sandbox-only app: nothing is redacted. Long strings are truncated to keep lines readable.
      def scrub(str) = str.length > MAX_STRING ? "#{str[0, MAX_STRING]}…(+#{str.length - MAX_STRING} chars)" : str.dup

      private

      def min_level = [@stderr_level || 1, @file_level || 0].min

      def emit(level, event, msg, fields)
        configure unless configured?
        return nil unless enabled?(level)
        entry = { ts: Time.now.utc.iso8601(3), level: level.to_s, event: event.to_s }
        entry[:msg] = scrub(msg.to_s) if msg
        entry.merge!(context.merge(fields).transform_values { |v| normalize(v) })
        @mutex.synchronize do
          entry[:seq] = (@seq += 1)
          if LEVELS[level] >= @file_level
            @buffer << entry
            @buffer.shift(@buffer.size - @buffer_size) if @buffer.size > @buffer_size
            @file&.puts(JSON.generate(entry))
          end
          @io&.puts(@format == "json" ? JSON.generate(entry) : pretty(entry)) if LEVELS[level] >= @stderr_level
        end
        entry
      rescue StandardError => e
        # Logging must never break the app.
        @io&.puts("[log-failure] #{e.class}: #{e.message}") rescue nil
        nil
      end

      def normalize(v)
        case v
        when Money then v.to_s
        when Hash then v.transform_values { |x| normalize(x) }
        when Array then v.map { |x| normalize(x) }
        when String then scrub(v)
        when Symbol then v.to_s
        when Time then v.utc.iso8601(3)
        when Struct then normalize(v.to_h)
        else v
        end
      end

      def pretty(e)
        extras = e.except(:ts, :level, :event, :msg, :seq).map { |k, v| "#{k}=#{v.is_a?(String) ? v : JSON.generate(v)}" }.join(" ")
        "#{e[:ts][11, 12]} #{e[:level].upcase.ljust(5)} #{e[:event]}#{e[:msg] ? " — #{e[:msg]}" : ''} #{extras}".rstrip
      end

      def parse_level(level)
        sym = level.to_s.downcase.to_sym
        LEVELS.key?(sym) ? LEVELS[sym] : LEVELS[:info]
      end

      def elapsed_ms(started) = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)



    end
  end
end
