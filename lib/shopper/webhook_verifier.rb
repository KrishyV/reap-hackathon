require "openssl"

module Shopper
  # Verifies X-Reap-Webhook-Signature: "t=<unix>,v1=<hex hmac-sha256 of "t.raw_body">".
  module WebhookVerifier
    TOLERANCE = 300

    class Invalid < StandardError; end

    module_function

    def sign(secret, raw_body, timestamp)
      "t=#{timestamp},v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{raw_body}")}"
    end

    def verify!(secret:, raw_body:, header:, now: Time.now.to_i)
      raise Invalid, "missing secret" if secret.to_s.empty?
      parts = header.to_s.split(",").filter_map { |kv| kv.split("=", 2).then { _1 if _1.size == 2 } }.to_h
      ts = Integer(parts["t"], exception: false)
      sig = parts["v1"].to_s
      raise Invalid, "malformed header" if ts.nil? || sig.empty?
      raise Invalid, "timestamp outside tolerance" if (now - ts).abs > TOLERANCE
      expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{ts}.#{raw_body}")
      raise Invalid, "bad signature" unless expected.bytesize == sig.bytesize && OpenSSL.fixed_length_secure_compare(expected, sig)
      true
    end
  end
end
