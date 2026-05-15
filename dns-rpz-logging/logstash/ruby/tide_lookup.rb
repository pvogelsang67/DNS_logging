require "net/http"
require "uri"
require "json"
require "monitor"

TIDE_CACHE_TTL    = 6 * 3600   # 6 hours
TIDE_CACHE_MAX    = 1_000
HTTP_CONN_MAX_AGE = 270        # Proactive reconnect at 270s (before server idles out at ~300s)

# ---------------------------------------------------------------------------
# register — called once per pipeline worker at startup
# API key is injected via script_params in logstash.conf or ENV fallback.
#
# logstash.conf example:
#   ruby {
#     path          => "/etc/logstash/tide_enrich.rb"
#     script_params => { "api_key" => "${TIDE_API_KEY}" }
#   }
# ---------------------------------------------------------------------------
def register(params)
  @api_key = params["api_key"] || ENV["TIDE_API_KEY"]
  
  raise "TIDE API key not configured. Set script_params 'api_key' or ENV 'TIDE_API_KEY'." if @api_key.nil? || @api_key.empty?

  @tide_cache     = {}
  @tide_cache_mon = Monitor.new
end

# ---------------------------------------------------------------------------
# tide_http — returns a live, per-thread Net::HTTP session.
#
# Logstash runs one Ruby filter instance per pipeline worker thread.
# Storing the connection in Thread.current gives each worker its own
# persistent session without any locking, so workers scale independently.
#
# The session is rebuilt when:
#   (a) it has never been created for this thread, or
#   (b) Net::HTTP reports it is no longer started, or
#   (c) it has exceeded HTTP_CONN_MAX_AGE (proactive idle-close avoidance)
# ---------------------------------------------------------------------------
def tide_http
  conn      = Thread.current[:tide_http]
  born_at   = Thread.current[:tide_http_born_at]
  now       = Time.now

  if conn.nil? || !conn.started? || (now - born_at) >= HTTP_CONN_MAX_AGE
    begin
      conn.finish if conn&.started?
    rescue
      # Ignore errors closing a stale socket
    end

    conn = Net::HTTP.new("csp.infoblox.com", 443)
    conn.use_ssl      = true
    conn.open_timeout = 5
    conn.read_timeout = 10
    conn.start

    Thread.current[:tide_http]         = conn
    Thread.current[:tide_http_born_at] = now
  end

  conn
end

# Force-discard the per-thread session so the next tide_http call rebuilds it.
def reset_tide_http
  begin
    Thread.current[:tide_http]&.finish
  rescue
  end
  Thread.current[:tide_http]         = nil
  Thread.current[:tide_http_born_at] = nil
end

# ---------------------------------------------------------------------------
# filter — main enrichment logic
# ---------------------------------------------------------------------------
def filter(event)
  qname = event.get("dns.qname")
  return [event] unless qname && !qname.empty?

  now    = Time.now
  result = nil

  # Cache read
  @tide_cache_mon.synchronize do
    entry = @tide_cache[qname]
    if entry && (now - entry[:inserted_at]) < TIDE_CACHE_TTL
      result = entry[:data]
    else
      @tide_cache.delete(qname)
    end
  end

  # API call on cache miss
  if result.nil?
    uri = URI("https://csp.infoblox.com/tide/api/data/threats")
    uri.query = URI.encode_www_form("text_search" => qname, "type" => "host", "rlimit" => "1")

    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Token token=#{@api_key}"

    response = nil
    attempts = 0

    begin
      attempts += 1
      response = tide_http.request(request)

    rescue Net::ReadTimeout, Net::OpenTimeout,
           EOFError, Errno::ECONNRESET, Errno::EPIPE, IOError => e
      # Socket is dead — discard it and retry with a fresh connection
      reset_tide_http
      retry if attempts < 3
      event.set("tide.error", "connection failed after #{attempts} attempts: #{e.message}")
      return [event]

    rescue => e
      event.set("tide.error", e.message)
      return [event]
    end

    case response.code
    when "200"
      threats = JSON.parse(response.body)["threat"] || []
      if threats.empty?
        result = { hit: false }
      else
        best   = threats.max_by { |t| t["threat_level"].to_i }
        result = {
          hit:          true,
          threat_level: best["threat_level"].to_i,
          profile:      best["profile"],
          property:     best["property"],
          threat_class: best["class"],
          confidence:   best["confidence"]&.to_i
        }
      end

    when "404"
      result = { hit: false }

    when "429"
      event.set("tide.error", "TIDE rate limited (429)")
      return [event]

    else
      event.set("tide.error", "HTTP #{response.code}: #{response.body[0, 200]}")
      return [event]
    end

    # Cache write
    @tide_cache_mon.synchronize do
      @tide_cache.delete(@tide_cache.first.first) if @tide_cache.size >= TIDE_CACHE_MAX
      @tide_cache[qname] = { inserted_at: now, data: result }
    end
  end

  # Enrich event
  event.set("tide.hit", result[:hit])
  if result[:hit]
    event.set("tide.threat_level", result[:threat_level])
    event.set("tide.profile",      result[:profile])
    event.set("tide.property",     result[:property])
    event.set("tide.threat_class", result[:threat_class])
    event.set("tide.confidence",   result[:confidence]) if result[:confidence]
  end

  [event]
end
