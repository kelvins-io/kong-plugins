local llm_usage = require "kong.plugins.response-ratelimiting-advanced.llm_usage"
local log = require "kong.plugins.response-ratelimiting-advanced.log"


local kong = kong
local type = type
local tostring = tostring
local concat = table.concat


local function finish_usage(conf, ctx)
  local increments, err
  if ctx.is_sse then
    llm_usage.flush_sse(ctx)
    increments, err = llm_usage.increments_from_json(conf.limits, ctx.sse_last_data)
  else
    local json_str
    if ctx.json_parts then
      json_str = concat(ctx.json_parts)
      ctx.json_parts = nil
    end
    increments, err = llm_usage.increments_from_json(conf.limits, json_str)
  end

  if err then
    kong.log.warn("llm_usage: ", tostring(err))
  end

  ctx.increments = increments or {}
end


local _M = {}


function _M.execute(conf)
  if not llm_usage.enabled(conf) then
    return
  end

  local ctx = kong.ctx.plugin
  if ctx.skip_quota or log.is_cache_hit() then
    ctx.skip_quota = true
    ctx.increments = {}
    return
  end
  local chunk, eof = ngx.arg[1], ngx.arg[2]

  if ctx.is_sse == nil and type(chunk) == "string" and chunk ~= "" then
    ctx.is_sse = llm_usage.looks_like_sse(chunk)
  end

  if ctx.is_sse then
    if type(chunk) == "string" and chunk ~= "" then
      llm_usage.consume_sse(ctx, chunk)
    end
  else
    if type(chunk) == "string" and chunk ~= "" then
      local parts = ctx.json_parts
      if not parts then
        parts = {}
        ctx.json_parts = parts
      end
      parts[#parts + 1] = chunk
    end
  end

  if eof then
    finish_usage(conf, ctx)
  end
end


return _M
