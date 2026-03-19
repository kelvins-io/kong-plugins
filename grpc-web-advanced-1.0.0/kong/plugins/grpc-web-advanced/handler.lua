-- Copyright (c) Kong Inc. 2020

local deco = require "kong.plugins.grpc-web-advanced.deco"
local proto_loader = require "kong.plugins.grpc-web-advanced.proto_loader"

local ngx = ngx
local kong = kong

local string_format = string.format

local ngx_arg = ngx.arg
local ngx_var = ngx.var

local kong_request_get_path = kong.request.get_path
local kong_request_get_header = kong.request.get_header
local kong_request_get_method = kong.request.get_method
local kong_request_get_raw_body = kong.request.get_raw_body
local kong_response_exit = kong.response.exit
local kong_response_set_header = kong.response.set_header
local kong_service_request_set_header = kong.service.request.set_header
local kong_service_request_set_raw_body = kong.service.request.set_raw_body


local grpc_web_advanced = {
  PRIORITY = 3,
  VERSION = "1.0.0",
}


function grpc_web_advanced:init_worker()
  kong.cluster_events:subscribe("grpc-web-advanced:proto-cache-purge", function(payload)
    kong.log.debug("handling proto cache purge: ", payload)

    local seen = {}
    local total = 0
    local iter = kong.db.plugins:each()

    while true do
      local plugin, err = iter()
      if err then
        kong.log.err("proto cache purge: iter error: ", err)
        return
      end
      if not plugin then
        break
      end
      if plugin.name ~= "grpc-web-advanced" then
        goto continue
      end
      if payload ~= "all" and payload ~= plugin.id then
        goto continue
      end

      local cache_dir = proto_loader.get_cache_root(plugin.config)
      if not seen[cache_dir] then
        seen[cache_dir] = true
        local count, purge_err = proto_loader.purge_cache_dir(cache_dir)
        if purge_err then
          kong.log.err("proto cache purge failed: ", purge_err)
        else
          total = total + (count or 0)
        end
      end
      ::continue::
    end

    kong.log.info("proto cache purge: deleted ", total, " file(s) on this node")
  end)
end


local CORS_HEADERS = {
  ["Content-Type"] = "application/grpc-web-text+proto",
  ["Access-Control-Allow-Origin"] = "*",
  ["Access-Control-Allow-Methods"] = "POST",
  ["Access-Control-Allow-Headers"] = "content-type,x-grpc-web,x-user-agent",
}

function grpc_web_advanced:access(conf)
  kong_response_set_header("Access-Control-Allow-Origin", conf.allow_origin_header)

  if kong_request_get_method() == "OPTIONS" then
    CORS_HEADERS["Access-Control-Allow-Origin"] = conf.allow_origin_header
    return kong_response_exit(200, "OK", CORS_HEADERS)
  end

  local uri
  if conf.pass_stripped_path then
    uri = ngx.var.upstream_uri
    ngx.req.set_uri(uri)
  else
    uri = kong_request_get_path()
  end

  local proto_path, proto_err = proto_loader.resolve_proto(conf.proto, conf)
  if conf.proto and conf.proto ~= "" and not proto_path then
    local msg = proto_err or "failed to resolve proto"
    kong.log.err(msg)
    return kong_response_exit(502, msg)
  end

  local dec, err = deco.new(
    kong_request_get_header("Content-Type"),
    uri, proto_path)

  if not dec then
    kong.log.err(err)
    return kong_response_exit(400, err)
  end

  kong.ctx.plugin.dec = dec

  kong_service_request_set_header("Content-Type", "application/grpc")
  kong_service_request_set_header("TE", "trailers")
  kong_service_request_set_raw_body(dec:upstream(kong_request_get_raw_body()))
end


function grpc_web_advanced:header_filter(conf)
  if kong_request_get_method() == "OPTIONS" then
    return
  end

  local dec = kong.ctx.plugin.dec
  if dec then
    kong_response_set_header("Content-Type", dec.mimetype)
  end
end


function grpc_web_advanced:body_filter(conf)
  if kong_request_get_method() ~= "POST" then
    return
  end
  local dec = kong.ctx.plugin.dec
  if not dec then
    return
  end

  local chunk, eof = ngx_arg[1], ngx_arg[2]

  chunk = dec:downstream(chunk)

  if eof and dec.framing == "grpc" then
    chunk = chunk .. dec:frame(0x80, string_format(
      "grpc-status:%s\r\ngrpc-message:%s\r\n",
      ngx_var["sent_trailer_grpc_status"] or "0",
      ngx_var["sent_trailer_grpc_message"] or ""))
  end

  ngx_arg[1] = chunk
end


return grpc_web_advanced
