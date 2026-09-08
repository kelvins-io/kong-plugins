-- Copyright (C) Kong Inc.

local access = require "kong.plugins.response-ratelimiting-advanced.access"
local log = require "kong.plugins.response-ratelimiting-advanced.log"
local header_filter = require "kong.plugins.response-ratelimiting-advanced.header_filter"
local body_filter = require "kong.plugins.response-ratelimiting-advanced.body_filter"


local ResponseRateLimitingHandler = {}


function ResponseRateLimitingHandler:access(conf)
  access.execute(conf)
end


function ResponseRateLimitingHandler:header_filter(conf)
  header_filter.execute(conf)
end


function ResponseRateLimitingHandler:body_filter(conf)
  body_filter.execute(conf)
end


function ResponseRateLimitingHandler:log(conf)
  local ctx = kong.ctx.plugin
  if ctx.skip_quota or log.is_cache_hit() then
    return
  end
  if not ctx.stop_log and ctx.usage then
    log.execute(conf, ctx.identifier, ctx.current_timestamp, ctx.increments, ctx.usage)
  end
end


ResponseRateLimitingHandler.PRIORITY = 900
ResponseRateLimitingHandler.VERSION = "1.0.0"


return ResponseRateLimitingHandler
