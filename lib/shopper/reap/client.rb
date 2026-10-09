require "net/http"
require "json"
require "securerandom"
require "digest"

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
        loop do
          attempt += 1
          can_retry = attempt <= @max_retries && (method == :get || idempotency_key)
          begin
            res = perform(method, path, body, idempotency_key, headers)
          rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, EOFError, SocketError => e
            raise Error.new(status: 0, code: "NETWORK", message: e.message) unless can_retry
            log("#{method.upcase} #{path} -> network error, retrying")
            @sleeper.call(0.5 * attempt)
            next
          end
          parsed = parse(res.body)
          status = res.code.to_i
          if status.between?(200, 299)
            log("#{method.upcase} #{path} -> #{status}")
            return parsed
          end
          err = parsed.is_a?(Hash) ? (parsed["error"] || {}) : {}
          err = {} unless err.is_a?(Hash)
          error = Error.new(status:, code: err["code"] || parsed.is_a?(Hash) && parsed["code"] || "HTTP_#{status}",
                            message: err["message"] || (parsed.is_a?(Hash) && parsed["message"]) || res.body.to_s[0, 200], detail: err["detail"])
          raise error unless RETRYABLE.include?(status) && can_retry
          log("#{method.upcase} #{path} -> #{status}, retrying")
          @sleeper.call(0.5 * attempt)
        end
      end

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
