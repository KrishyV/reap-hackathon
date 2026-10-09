require "net/http"
require "json"
require "securerandom"
require "digest"
require_relative "../log"

module Shopper
  module Reap
    class Error < StandardError
      attr_reader :status, :code, :detail

      def initialize(status:, code:, message:, detail: nil)
        @status = status
        @code = code
        @detail = detail
        super("Reap #{status} #{code}: #{message}")
      end
    end

    # Deterministic idempotency keys: a retried step replays Reap's first response
    # instead of creating a second card, quote, or charge.
    module Idempotency
      module_function

      def key(*parts)
        raise ArgumentError, "idempotency key needs parts" if parts.empty?
        # Backslash-escape the separator and the escape char so distinct part lists never join to the same string.
        Digest::SHA256.hexdigest(parts.map { |p| p.to_s.gsub(/[\\|]/) { "\\#{_1}" } }.join("|"))
      end
    end

    class Client
      RETRYABLE = [408, 425, 429, 500, 502, 503, 504].freeze

      def initialize(api_key:, base_url: "https://sandbox.api.reap.global", version: "2025-02-14",
                     max_retries: 2, logger: nil, sleeper: ->(s) { sleep(s) })
        raise ArgumentError, "REAP_API_KEY missing" if api_key.to_s.empty?
        @api_key = api_key
        @base = URI(base_url)
        @version = version
        @max_retries = max_retries
        @logger = logger
        @sleeper = sleeper
      end

      def sandbox? = @base.host.include?("sandbox")

      def get(path) = request(:get, path)

      # Every POST carries an Idempotency-Key; pass a deterministic one for money-moving steps.
      def post(path, body = {}, idempotency_key: SecureRandom.uuid, headers: {})
        request(:post, path, body, idempotency_key:, headers:)
      end

      private

      def request(method, path, body = nil, idempotency_key: nil, headers: {})
        attempt = 0
        call_id = SecureRandom.hex(4)
        verb = method.to_s.upcase
        idem = idempotency_key && idempotency_key[0, 12]
        Log.debug("reap.request", call_id:, method: verb, path:, idempotency_key: idem, extra_headers: headers.keys, body:)
        loop do
          attempt += 1
          can_retry = attempt <= @max_retries && (method == :get || idempotency_key)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            res = perform(method, path, body, idempotency_key, headers)
          rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, EOFError, SocketError => e
            Log.warn("reap.network_error", call_id:, method: verb, path:, attempt:, will_retry: !!can_retry,
                                           error: e.class.name, error_message: e.message, duration_ms: ms_since(started))
            raise Error.new(status: 0, code: "NETWORK", message: e.message) unless can_retry
            log("#{verb} #{path} -> network error, retrying")
            @sleeper.call(0.5 * attempt)
            next
          end
          parsed = parse(res.body)
          status = res.code.to_i
          meta = { call_id:, method: verb, path:, status:, attempt:, idempotency_key: idem, duration_ms: ms_since(started),
                   reap_request_id: res["x-request-id"] || res["reap-request-id"], idempotent_replay: res["idempotent-replayed"] }.compact
          if status.between?(200, 299)
            Log.info("reap.response", **meta)
            Log.debug("reap.response_body", call_id:, path:, body: parsed)
            log("#{verb} #{path} -> #{status}")
            return parsed
          end
          err = parsed.is_a?(Hash) ? (parsed["error"] || {}) : {}
          err = {} unless err.is_a?(Hash)
          error = Error.new(status:, code: err["code"] || parsed.is_a?(Hash) && parsed["code"] || "HTTP_#{status}",
                            message: err["message"] || (parsed.is_a?(Hash) && parsed["message"]) || res.body.to_s[0, 200], detail: err["detail"])
          retrying = RETRYABLE.include?(status) && can_retry
          Log.public_send(retrying ? :warn : (status >= 500 ? :error : :warn), "reap.error",
                          **meta, code: error.code, error_message: error.message, detail: error.detail, will_retry: !!retrying, body: parsed)
          raise error unless retrying
          log("#{verb} #{path} -> #{status}, retrying")
          @sleeper.call(0.5 * attempt)
        end
      end

      def ms_since(started) = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)

      def perform(method, path, body, idempotency_key, headers)
        uri = URI.join(@base.to_s, path)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = 60
        req = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri)
        req["Authorization"] = "Bearer #{@api_key}"
        req["Reap-Version"] = @version
        req["Accept"] = "application/json"
        req["Idempotency-Key"] = idempotency_key if idempotency_key
        headers.each { |k, v| req[k] = v }
        if body
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(body)
        end
        http.request(req)
      end

      def parse(text)
        return nil if text.nil? || text.empty?
        JSON.parse(text.dup.force_encoding("UTF-8"))
      rescue JSON::ParserError
        text
      end

      def log(msg) = @logger&.call(msg)
    end
  end
end
