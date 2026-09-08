local policies = require "kong.plugins.response-ratelimiting-advanced.policies"
local pairs = pairs
local type = type


local _M = {}


local function header_value(name)
  local value = kong.response.get_header(name)
  if type(value) == "table" then
    value = value[1]
  end
  if type(value) ~= "string" then
    return nil
  end
  return value:lower()
end


function _M.is_cache_hit()
  return header_value("X-Cache-Status") == "hit"
end


local function log(premature, conf, identifier, current_timestamp, increments, usage)
  if premature then
    return
  end

  if not increments or not usage then
    return
  end

  -- Increment metrics for all periods if the request goes through
  for k in pairs(usage) do
    if increments[k] and increments[k] ~= 0 then
      policies[conf.policy].increment(conf, identifier, k, current_timestamp, increments[k])
    end
  end
end


function _M.execute(conf, identifier, current_timestamp, increments, usage)
  -- Cache hits must be skipped in this phase (request context). The timer
  -- callback cannot read response headers.
  if _M.is_cache_hit() then
    return
  end

  local ok, err = ngx.timer.at(0, log, conf, identifier, current_timestamp, increments, usage)
  if not ok then
    kong.log.err("failed to create timer: ", err)
  end
end


return _M
