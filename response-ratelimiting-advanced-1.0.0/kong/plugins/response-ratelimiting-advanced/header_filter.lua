local llm_usage = require "kong.plugins.response-ratelimiting-advanced.llm_usage"
local log = require "kong.plugins.response-ratelimiting-advanced.log"


local kong = kong
local next = next
local type = type
local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local math_max = math.max


local strip, split
do
  local ok, kong_string = pcall(require, "kong.tools.string")
  if ok and kong_string.strip and kong_string.split then
    strip = kong_string.strip
    split = kong_string.split
  else
    local utils = require "kong.tools.utils"
    strip = utils.strip
    split = utils.split
  end
end


local RATELIMIT_LIMIT = "X-RateLimit-Limit"
local RATELIMIT_REMAINING = "X-RateLimit-Remaining"


local function parse_header(header_value, limits)
  local increments = {}

  if header_value then
    local parts
    if type(header_value) == "table" then
      parts = header_value
    else
      parts = split(header_value, ",")
    end

    for _, v in ipairs(parts) do
      local increment_parts = split(v, "=")
      if #increment_parts == 2 then
        local limit_name = strip(increment_parts[1])
        if limits[limit_name] then -- Only if the limit exists
          increments[strip(increment_parts[1])] = tonumber(strip(increment_parts[2]))
        end
      end
    end
  end

  return increments
end


local _M = {}


function _M.execute(conf)
  kong.ctx.plugin.increments = {}

  if not next(conf.limits) then
    return
  end

  local increments
  if log.is_cache_hit() then
    -- Cached responses must not consume quota (header or llm_usage).
    kong.ctx.plugin.skip_quota = true
    increments = {}
  elseif llm_usage.enabled(conf) then
    -- Body (JSON / SSE) is parsed in body_filter so SSE can flush to the client
    -- as it arrives. Increments are filled when the stream ends.
    increments = {}
    local ct = kong.service.response.get_header("Content-Type")
    if llm_usage.is_sse_content_type(ct) then
      kong.ctx.plugin.is_sse = true
    elseif type(ct) == "table" then
      ct = ct[1]
      if type(ct) == "string" and ct ~= "" then
        kong.ctx.plugin.is_sse = false
      end
    elseif type(ct) == "string" and ct ~= "" then
      kong.ctx.plugin.is_sse = false
    end
  else
    increments = parse_header(kong.service.response.get_header(conf.header_name), conf.limits)
  end

  kong.ctx.plugin.increments = increments

  local usage = kong.ctx.plugin.usage -- Load current usage
  if not usage then
    return
  end

  local llm_usage_on = llm_usage.enabled(conf)
  local stop
  for limit_name in pairs(usage) do
    for period_name, lv in pairs(usage[limit_name]) do
      if not conf.hide_client_headers then
        local limit_hdr  = RATELIMIT_LIMIT .. "-" .. limit_name .. "-" .. period_name
        local remain_hdr = RATELIMIT_REMAINING .. "-" .. limit_name .. "-" .. period_name
        local remain = math_max(0, lv.remaining - (increments[limit_name] and increments[limit_name] or 0))

        kong.response.set_header(limit_hdr, lv.limit)
        kong.response.set_header(remain_hdr, remain)
      end

      if increments[limit_name] and increments[limit_name] > 0 and lv.remaining <= 0 then
        stop = true -- No more
      elseif llm_usage_on and lv.remaining <= 0 then
        -- Quota already exhausted; refuse before the SSE/JSON body is sent.
        stop = true
      end
    end
  end

  kong.response.clear_header(conf.header_name)

  -- If limit is exceeded, terminate the request
  if stop then
    kong.ctx.plugin.stop_log = true
    return kong.response.exit(429) -- Don't set a body
  end
end


return _M
