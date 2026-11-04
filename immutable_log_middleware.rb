# frozen_string_literal: true

# ImmutableLog Rack middleware for Rails (7.1+; works on 6.x/7.0 with the concrete path as
# http_route). Copy this file to lib/immutable_log_middleware.rb and register it in
# config/application.rb (see the README). Uses only the Ruby standard library.

require "ipaddr"
require "json"
require "logger"
require "net/http"
require "securerandom"
require "time"
require "uri"

class ImmutableLogMiddleware
  DEFAULT_API_URL = "https://api.immutablelog.com"
  MAX_ERROR_MESSAGE = 500
  MAX_PATH = 2048
  MAX_USER_AGENT = 512
  MAX_TRAIL = 256
  RETRYABLE = [408, 429, 500, 502, 503, 504].freeze

  # Keys a controller sets in request.env to customise the event.
  EVENT_NAME_KEY = "imtbl.event_name"
  TRAIL_KEY = "imtbl.trail"

  def initialize(app,
                 api_key: ENV["IMTBL_API_KEY"],
                 api_url: ENV["IMTBL_URL"],
                 service: ENV["IMTBL_SERVICE_NAME"],
                 env: ENV["IMTBL_ENV"],
                 skip_paths: %w[/health /healthz /up],
                 trust_trail_header: false,
                 timeout: 5,
                 logger: nil)
    @app = app
    @api_key = api_key.to_s
    @endpoint = URI.join(blank?(api_url) ? DEFAULT_API_URL : api_url.to_s.chomp("/") + "/", "v1/events")
    @service = blank?(service) ? "rails-service" : service.to_s
    @env_name = blank?(env) ? "production" : env.to_s
    @skip_paths = skip_paths.to_a.map(&:to_s).freeze
    # X-Imtbl-Trail is controlled by whoever calls the service: off unless you opt in.
    @trust_trail_header = trust_trail_header
    @timeout = timeout
    @logger = logger
    log_warn("IMTBL_API_KEY is empty: no event will be sent") if @api_key.empty?
  end

  def call(env)
    method = env["REQUEST_METHOD"].to_s
    path = env["PATH_INFO"].to_s
    # Preflight and skipped paths never generate an event.
    return @app.call(env) if @api_key.empty? || method == "OPTIONS" || @skip_paths.include?(path)

    facts = {
      started: Process.clock_gettime(Process::CLOCK_MONOTONIC),
      method: method.dup,
      path: path[0, MAX_PATH],
      user_agent: env["HTTP_USER_AGENT"].to_s[0, MAX_USER_AGENT],
      client_ip: self.class.client_ip(env["HTTP_X_FORWARDED_FOR"], env["HTTP_X_REAL_IP"], env["REMOTE_ADDR"]),
      header_trail: @trust_trail_header ? env["HTTP_X_IMTBL_TRAIL"]&.dup : nil,
    }

    begin
      status, headers, body = @app.call(env)
    rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised right below
      # The exception has not become a response yet: Rails' ShowExceptions answers it (500
      # for most errors) after this middleware.
      dispatch(facts, 500, env, e)
      raise
    end
    dispatch(facts, status.to_i, env, nil)
    [status, headers, body]
  end

  # client_ip for the SIEM: first entry of X-Forwarded-For, then X-Real-IP, then REMOTE_ADDR.
  # Only a bare IP is returned (no port): the SIEM drops "ip:port" silently. The headers are
  # read directly, without ActionDispatch::RemoteIp; see "Proxy e X-Forwarded-For" in the README.
  def self.client_ip(xff, real_ip, remote_addr)
    bare_ip(xff.to_s.split(",").first) || bare_ip(real_ip) || bare_ip(remote_addr)
  end

  # "203.0.113.7", "203.0.113.7:4711", "[2001:db8::1]:8080", "2001:db8::1" -> bare IP.
  def self.bare_ip(raw)
    s = raw.to_s.strip
    return nil if s.empty? || s.include?("/") # IPAddr would accept a CIDR range
    host =
      if s.start_with?("[") then s[1...(s.index("]") || 1)].to_s
      elsif s.count(":") == 1 then s.split(":").first.to_s
      else s
      end
    ip = IPAddr.new(host)
    (ip.ipv4_mapped? ? ip.native : ip).to_s # "::ffff:10.0.0.1" -> "10.0.0.1"
  rescue IPAddr::Error, ArgumentError
    nil
  end

  # The core rejects a trail that is empty, longer than 256 chars or contains ':'.
  def self.sanitize_trail(value)
    return nil if value.nil?
    s = value.to_s.strip.tr(":", "-")[0, MAX_TRAIL]
    s.empty? ? nil : s
  end

  private

  # Reads what the app left in env (route, custom name, trail) here, on the request thread,
  # and hands the background thread only plain strings, never env (copy, then spawn).
  def dispatch(facts, status, env, exception)
    event = build_event(facts, status, env, exception)
    Thread.new { post(event) }
  rescue StandardError => e
    log_warn("failed to build event: #{e.message}")
  end

  def build_event(facts, status, env, exception)
    kind = status >= 400 ? "error" : status >= 300 ? "info" : status >= 200 ? "success" : "info"
    request_id = SecureRandom.uuid
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - facts[:started]) * 1000).round
    path = facts[:path]
    event_name = (env[EVENT_NAME_KEY] || "http.#{facts[:method]}.#{path}").to_s
    trail = self.class.sanitize_trail(env[TRAIL_KEY] || facts[:header_trail])
    error_type = exception&.class&.name
    error_message = exception&.message.to_s[0, MAX_ERROR_MESSAGE]

    payload = {
      "id" => SecureRandom.uuid,
      "kind" => kind,
      "message" => "#{facts[:method]} #{path} -> #{status}",
      "timestamp" => Time.now.utc.iso8601,
      "context" => { "ip" => facts[:client_ip] || "unknown", "user_agent" => facts[:user_agent] },
      "request" => { "request_id" => request_id, "method" => facts[:method], "path" => path },
      "metrics" => { "latency_ms" => latency_ms, "status_code" => status },
      "severity" => kind == "error" ? "high" : "low",
    }
    if kind == "error"
      payload["error"] = { "status_code" => status, "retryable" => RETRYABLE.include?(status) }
      if error_type
        payload["error"]["exception"] = error_type
        payload["error"]["exception_message"] = error_message
      end
    end

    # meta is a string -> string map in the core: every value goes through to_s
    # (http_status is "200", never 200).
    meta = {
      "type" => kind,
      "event_type" => kind,
      "event_name" => event_name,
      "service" => @service,
      "request_id" => request_id,
      # "env" is the legacy key; "environment" is the canonical one (CONTRACT.md §4.1).
      "env" => @env_name,
      "environment" => @env_name,
      "http_method" => facts[:method],
      "http_status" => status.to_s,
      "http_route" => route_template(env) || path,
      "log_level" => log_level(kind),
    }
    meta["client_ip"] = facts[:client_ip] if facts[:client_ip]
    if error_type
      meta["error_type"] = error_type
      meta["error_message"] = error_message unless error_message.empty?
    end
    meta["immutable_trail"] = trail if trail

    { request_id: request_id, body: JSON.generate("payload" => JSON.generate(payload), "meta" => meta) }
  end

  # Route template from the Rails router (7.1+): "/users/:id(.:format)" -> "/users/:id".
  # Rails 7.1/7.2 write it to env["action_dispatch.route_uri_pattern"]; Rails 8.1 only keeps the
  # route object in env["action_dispatch.route"] and computes the pattern on demand in
  # Request#route_uri_pattern, so the public method is asked first; the env key is the fallback.
  # Missing on a 404 and on Rails < 7.1: the caller falls back to the concrete path.
  def route_template(env)
    pattern = nil
    if defined?(ActionDispatch::Request) && ActionDispatch::Request.method_defined?(:route_uri_pattern)
      pattern = ActionDispatch::Request.new(env).route_uri_pattern
    end
    pattern = env["action_dispatch.route_uri_pattern"] if blank?(pattern)
    return nil if blank?(pattern)
    pattern.to_s.sub(/\(\.:format\)\z/, "")
  end

  def post(event)
    http = Net::HTTP.new(@endpoint.host, @endpoint.port)
    http.use_ssl = @endpoint.scheme == "https"
    http.open_timeout = [@timeout, 1].min
    http.read_timeout = @timeout
    http.write_timeout = @timeout
    req = Net::HTTP::Post.new(@endpoint)
    req["Content-Type"] = "application/json"
    req["Authorization"] = "Bearer #{@api_key}"
    req["Idempotency-Key"] = event[:request_id]
    req.body = event[:body]
    res = http.request(req)
    log_warn("event rejected: HTTP #{res.code}") unless res.is_a?(Net::HTTPSuccess)
  rescue StandardError => e
    log_warn("failed to send event: #{e.class}: #{e.message}")
  end

  def log_level(kind)
    { "error" => "error", "warning" => "warn", "debug" => "debug" }.fetch(kind, "info")
  end

  def log_warn(msg)
    logger = @logger || (defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger) || (@fallback_logger ||= Logger.new($stderr))
    logger.warn("[ImmutableLog] #{msg}")
  end

  def blank?(v)
    v.nil? || v.to_s.strip.empty?
  end
end
