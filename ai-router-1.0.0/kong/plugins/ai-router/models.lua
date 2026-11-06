-- OpenAI-compatible GET /v1/models listing from model_list.
local cjson = require "cjson.safe"
local router = require "kong.plugins.ai-router.router"
local providers = require "kong.plugins.ai-router.providers"
local virtual_keys = require "kong.plugins.ai-router.virtual_keys"

local kong = kong
local type = type
local ipairs = ipairs
local tonumber = tonumber
local tostring = tostring
local find = string.find
local sub = string.sub
local lower = string.lower


local _M = {}


local function is_models_path(path)
  if not path then
    return false
  end
  path = lower(path)
  return path == "/models" or path == "/v1/models"
    or sub(path, -7) == "/models"
    or find(path, "/v1/models$", 1) ~= nil
end


function _M.matches(path, method)
  method = method or kong.request.get_method()
  if method ~= "GET" and method ~= "HEAD" then
    return false
  end
  return is_models_path(path or kong.request.get_path())
end


local function build_data(conf, vk)
  local groups = router.index_model_list(conf.model_list)
  local data = {}
  local seen = {}

  -- stable-ish order: follow model_list order of first occurrence
  for _, entry in ipairs(conf.model_list or {}) do
    local name = entry.model_name
    if name and not seen[name] then
      seen[name] = true
      if virtual_keys.model_allowed(vk, name) then
        local resolved = providers.resolve(entry)
        local provider = resolved and resolved.provider or "openai"
        local info = entry.model_info or {}
        data[#data + 1] = {
          id = name,
          object = "model",
          created = tonumber(info.created) or 0,
          owned_by = info.owned_by or provider,
          ["ai-router"] = {
            provider = provider,
            upstream_model = resolved and resolved.upstream_model or nil,
            deployments = #(groups[name] or {}),
          },
        }
      end
    end
  end

  return {
    object = "list",
    data = data,
  }
end


function _M.handle(conf)
  local vk, err, status = virtual_keys.authenticate(conf)
  if conf.enable_virtual_keys then
    if err then
      return kong.response.exit(status or 401, {
        error = { message = err, type = "authentication_error" },
      })
    end
  end

  local body = build_data(conf, vk)
  local headers = { ["Content-Type"] = "application/json" }
  if conf.response_headers then
    headers["x-ai-router-models"] = tostring(#(body.data or {}))
  end

  if kong.request.get_method() == "HEAD" then
    return kong.response.exit(200, nil, headers)
  end
  return kong.response.exit(200, cjson.encode(body), headers)
end


return _M
