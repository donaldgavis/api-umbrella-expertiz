local int64 = require "api-umbrella.utils.int64"
local is_empty = require "api-umbrella.utils.is_empty"
local lrucache = require "resty.lrucache.pureffi"
local pg_utils_query = require("api-umbrella.utils.pg_utils").query
local split = require("pl.utils").split
local table_clear = require "table.clear"
local table_copy = require("pl.tablex").copy
local table_new = require "table.new"

local ceil = math.ceil
local counters_dict = ngx.shared.rate_limit_counters
local exceeded_dict = ngx.shared.rate_limit_exceeded
local floor = math.floor
local int64_min_value_string = int64.MIN_VALUE_STRING
local int64_to_string = int64.to_string
local jobs_dict = ngx.shared.jobs
local now = ngx.now

-- Rate limit implementation loosely based on
-- https://blog.cloudflare.com/counting-things-a-lot-of-different-things/
--
-- - Each rate limit applied uses two counters: One for the current time period
--   and one for the previous time period. The estimated rate is calculated
--   based on these.
-- - When the rate limit has been exceeded, this is cached locally so no
--   further calculations are necessary for these requests.

local _M = {}

local exceeded_local_cache = lrucache.new(1000)
local distributed_counters_local_queue = table_new(0, 1000)

local function get_bucket_name(api, settings)
  local bucket_name
  if settings["rate_limit_bucket_name"] then
    bucket_name = settings["rate_limit_bucket_name"]
  else
    if api then
      bucket_name = api["frontend_host"]
    end

    if not bucket_name then
      bucket_name = "*"
    end
  end

  return bucket_name
end

local function get_rate_limit_key(self, rate_limit_index, rate_limit)
  local cached_key = self.rate_limit_keys[rate_limit_index]
  if cached_key then
    return cached_key
  end

  local limit_by = rate_limit["limit_by"]

  local key_limit_by
  if limit_by == "api_key" then
    key_limit_by = "k"
  elseif limit_by == "ip" then
    key_limit_by = "i"
  else
    ngx.log(ngx.ERR, "rate limit unknown limit by")
  end

  local user = self.user
  if not user or user["throttle_by_ip"] then
    limit_by = "ip"
  end

  local key_value
  if limit_by == "api_key" then
    key_value = user["api_key_prefix"]
  elseif limit_by == "ip" then
    key_value = self.remote_addr
  else
    ngx.log(ngx.ERR, "rate limit unknown limit by")
  end

  local key = key_limit_by .. "|" .. rate_limit["duration"] .. "|" .. self.bucket_name .. "|" .. key_value
  self.rate_limit_keys[rate_limit_index] = key
  return key
end

local function increment_distributed_counter(key)
  local value = distributed_counters_local_queue[key]
  if not value then
    distributed_counters_local_queue[key] = 1
  else
    distributed_counters_local_queue[key] = value + 1
  end
end

local function has_already_exceeded_any_limits(self)
  local current_time = self.current_time
  local exceed_expires_at
  local exceeded = false
  local header_remaining
  local header_reset

  -- Loop over each limit present and see if any one of them has been exceeded.
  for rate_limit_index, rate_limit in ipairs(self.rate_limits) do
    local rate_limit_key = get_rate_limit_key(self, rate_limit_index, rate_limit)

    exceed_expires_at = exceeded_local_cache:get(rate_limit_key)
    if exceed_expires_at then
      break
    else
      local exceed_expires_at_err
      exceed_expires_at, exceed_expires_at_err = exceeded_dict:get(rate_limit_key)
      if not exceed_expires_at and exceed_expires_at_err then
        ngx.log(ngx.ERR, "Error fetching rate limit exceeded: ", exceed_expires_at_err)
      elseif exceed_expires_at then
        exceeded_local_cache:set(rate_limit_key, exceed_expires_at, exceed_expires_at - current_time)
        break
      end
    end
  end

  if exceed_expires_at and exceed_expires_at >= current_time then
    exceeded = true
    header_remaining = 0
    header_reset = ceil(exceed_expires_at - current_time)
  end

  return exceeded, header_remaining, header_reset
end

local function check_limit(rate_limit_key, limit_to, duration, current_time, current_window_time, current_window_count)
  local exceeded = false
  local remaining
  local reset

  local estimated_count
  local time_in_previous_window
  if current_window_count > limit_to then
    time_in_previous_window = duration
    estimated_count = current_window_count
  else
    local previous_window_time = current_window_time - duration
    local previous_window_key = rate_limit_key .. "|" .. previous_window_time
    local previous_window_count, previous_window_count_err = counters_dict:get(previous_window_key)
    if not previous_window_count then
      if previous_window_count_err then
        ngx.log(ngx.ERR, "Error fetching rate limit counter: ", previous_window_count_err)
      end

      previous_window_count = 0
    end

    local time_in_current_window = current_time - current_window_time
    time_in_previous_window = (duration - time_in_current_window)
    estimated_count = floor(previous_window_count * (time_in_previous_window / duration) + current_window_count)
  end

  if estimated_count > limit_to then
    exceeded = true
    remaining = 0
    reset = ceil(time_in_previous_window)
    local exceed_expires_at = current_time + time_in_previous_window
    local set_ok, set_err, set_forcible = exceeded_dict:set(rate_limit_key, exceed_expires_at, reset)
    if not set_ok then
      ngx.log(ngx.ERR, "failed to set exceeded key in 'rate_limit_exceeded' shared dict: ", set_err)
    elseif set_forcible then
      ngx.log(ngx.WARN, "forcibly set exceeded key in 'rate_limit_exceeded' shared dict (shared dict may be too small)")
    end
  else
    remaining = limit_to - estimated_count
  end

  return exceeded, remaining, reset
end

local function increment_limit(self, rate_limit_index, rate_limit)
  local rate_limit_key = get_rate_limit_key(self, rate_limit_index, rate_limit)

  local current_time = self.current_time
  local duration = rate_limit["_duration_sec"]
  local current_window_time = floor(current_time / duration) * duration
  local current_window_key = rate_limit_key .. "|" .. current_window_time
  local current_window_ttl = duration * 2 + 1
  local current_window_count, incr_err, incr_forcible = counters_dict:incr(current_window_key, 1, 0, current_window_ttl)
  if incr_err then
    ngx.log(ngx.ERR, "failed to increment counters shared dict: ", incr_err)
  elseif incr_forcible then
    ngx.log(ngx.WARN, "forcibly set counter in 'rate_limit_counters' shared dict (shared dict may be too small)")
  end

  if rate_limit["distributed"] then
    increment_distributed_counter(current_window_key)
  end

  return check_limit(rate_limit_key, rate_limit["limit_to"], duration, current_time, current_window_time, current_window_count)
end

local function increment_all_limits(self)
  local exceeded = false
  local header_remaining
  local header_reset

  for rate_limit_index, rate_limit in ipairs(self.rate_limits) do
    local limit_exceeded, limit_remaining, limit_reset = increment_limit(self, rate_limit_index, rate_limit)

    if rate_limit["response_headers"] or limit_exceeded then
      header_remaining = limit_remaining
      header_reset = limit_reset
    end

    if limit_exceeded then
      exceeded = true
      break
    end
  end

  return exceeded, header_remaining, header_reset
end

function _M.check(api, settings, user, remote_addr)
  if settings["rate_limit_mode"] == "unlimited" then
    return false
  end

  local self = {
    api = api,
    settings = settings,
    user = user,
    current_time = now(),
    bucket_name = get_bucket_name(api, settings),
    rate_limits = settings["rate_limits"],
    rate_limit_keys = table_new(0, #settings["rate_limits"]),
    remote_addr = remote_addr,
  }

  local exceeded, header_remaining, header_reset = has_already_exceeded_any_limits(self)
  if not exceeded then
    exceeded, header_remaining, header_reset = increment_all_limits(self)
  end

  local header_limit = settings["_rate_limits_response_header_limit"]

  return exceeded, header_limit, header_remaining, header_reset
end

function _M.distributed_push()
  if is_empty(distributed_counters_local_queue) then
    return
  end

  local current_save_time = now()
  local data = table_copy(distributed_counters_local_queue)
  table_clear(distributed_counters_local_queue)

  local success = true
  for key, count in pairs(data) do
    local key_parts = split(key, "|", true)
    local duration = tonumber(key_parts[2])
    local window_start_time = tonumber(key_parts[5])
    local expires_at = (window_start_time + duration + 1)

    local result, err = pg_utils_query("INSERT INTO distributed_rate_limit_counters(id, value, expires_at) VALUES(:id, :value, to_timestamp(:expires_at)) ON CONFLICT (id) DO UPDATE SET value = distributed_rate_limit_counters.value + EXCLUDED.value", {
      id = key,
      value = count,
      expires_at = expires_at,
    }, { quiet = true })
    if not result then
      ngx.log(ngx.ERR, "failed to update rate limits in database: ", err)
      success = false
    end
  end

  if success then
    local set_ok, set_err, set_forcible = jobs_dict:set("rate_limit_counters_store_distributed_last_pushed_at", current_save_time * 1000)
    if not set_ok then
      ngx.log(ngx.ERR, "failed to set 'rate_limit_counters_store_distributed_last_pushed_at' in 'jobs' shared dict: ", set_err)
    elseif set_forcible then
      ngx.log(ngx.WARN, "forcibly set 'rate_limit_counters_store_distributed_last_pushed_at' in 'jobs' shared dict (shared dict may be too small)")
    end
  end
end

function _M.distributed_pull()
  local current_fetch_time = now()
  local last_fetched_version, last_fetched_version_err = jobs_dict:get("rate_limit_counters_store_distributed_last_fetched_version")
  if not last_fetched_version then
    if last_fetched_version_err then
      ngx.log(ngx.ERR, "Error fetching rate limit counter: ", last_fetched_version_err)
    end

    last_fetched_version = int64_min_value_string
  end

  -- Find any rate limit counters modified since the last poll.
  --
  -- Note the LEAST() and last_value sequence logic is to handle the edge case
  -- possibility of this sequence value cycling/wrapping once it reaches the
  -- maximum value for bigints. When that happens this sequence is setup to
  -- cycle and start over with negative values. Since the data in this table
  -- expires, there shouldn't be any duplicate version numbers by the time the
  -- sequence cycles.
  local results, err = pg_utils_query("SELECT id, version, value, extract(epoch FROM expires_at) AS expires_at FROM distributed_rate_limit_counters WHERE version > LEAST(:version, (SELECT last_value - 1 FROM distributed_rate_limit_counters_version_seq)) AND expires_at >= now() ORDER BY version DESC", { version = last_fetched_version }, { quiet = true })
  if not results then
    ngx.log(ngx.ERR, "failed to fetch rate limits from database: ", err)
    return nil
  end

  for index, row in ipairs(results) do
    if index == 1 then
      last_fetched_version = int64_to_string(row["version"])
    end

    local key = row["id"]
    local distributed_count = row["value"]
    local local_count, local_count_err = counters_dict:get(key)
    if not local_count then
      if local_count_err then
        ngx.log(ngx.ERR, "Error fetching rate limit counter: ", local_count_err)
      end

      local_count = 0
    end

    if distributed_count > local_count then
      local ttl = ceil(row["expires_at"] - current_fetch_time)
      if ttl < 0 then
        ngx.log(ngx.ERR, "distributed_rate_limit_puller ttl unexpectedly less than 0 (key: " .. key .. " ttl: " .. ttl .. ")")
        ttl = 60
      end

      local incr = distributed_count - local_count
      local _, incr_err, incr_forcible = counters_dict:incr(key, incr, 0, ttl)
      if incr_err then
        ngx.log(ngx.ERR, "failed to increment counters shared dict: ", incr_err)
      elseif incr_forcible then
        ngx.log(ngx.WARN, "forcibly set counter in 'rate_limit_counters' shared dict (shared dict may be too small)")
      end
    end
  end

  local set_ok, set_err, set_forcible = jobs_dict:set("rate_limit_counters_store_distributed_last_fetched_version", last_fetched_version)
  if not set_ok then
    ngx.log(ngx.ERR, "failed to set 'rate_limit_counters_store_distributed_last_fetched_version' in 'jobs' shared dict: ", set_err)
  elseif set_forcible then
    ngx.log(ngx.WARN, "forcibly set 'rate_limit_counters_store_distributed_last_fetched_version' in 'jobs' shared dict (shared dict may be too small)")
  end

  set_ok, set_err, set_forcible = jobs_dict:set("rate_limit_counters_store_distributed_last_pulled_at", current_fetch_time * 1000)
  if not set_ok then
    ngx.log(ngx.ERR, "failed to set 'rate_limit_counters_store_distributed_last_pulled_at' in 'jobs' shared dict: ", set_err)
  elseif set_forcible then
    ngx.log(ngx.WARN, "forcibly set 'rate_limit_counters_store_distributed_last_pulled_at' in 'jobs' shared dict (shared dict may be too small)")
  end
end

return _M
