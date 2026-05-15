require "monitor"

TIDE_CACHE_TTL = 6 * 3600
TIDE_CACHE_MAX = 1_000

@tide_cache     = {}
@tide_cache_mon = Monitor.new