-- Semantic routing: embed prompt & model descriptions, rank by cosine similarity.
local cjson = require "cjson.safe"
local http_client = require "kong.plugins.ai-router.http_client"
local redis_store = require "kong.plugins.ai-router.redis_store"
local tools = require "kong.plugins.ai-router.tools"

local ngx = ngx
local kong = kong
local type = type
local ipairs = ipairs
local pairs = pairs
local tonumber = tonumber
local tostring = tostring
local sqrt = math.sqrt
local concat = table.concat
local sort = table.sort


local _M = {}


local function trim_slash(s)
  return (s or ""):gsub("/+$", "")
end


local function dict(conf)
  local name = conf.shared_dict or "ai_router"
  return ngx.shared[name] or ngx.shared.kong
end


local function cache_get(conf, key)
  if conf.state_backend == "redis" then
    local v = redis_store.get(conf, "emb:" .. key)
    if type(v) == "string" and v ~= "" then
      return cjson.decode(v)
    end
    return nil
  end
  local d = dict(conf)
  if not d then
    return nil
  end
  local raw = d:get("emb:" .. key)
  if type(raw) ~= "string" or raw == "" then
    return nil
  end
  return cjson.decode(raw)
end


local function cache_set(conf, key, vec, ttl)
  local encoded = cjson.encode(vec)
  if not encoded then
    return
  end
  ttl = ttl or 86400
  if conf.state_backend == "redis" then
    redis_store.set(conf, "emb:" .. key, encoded, ttl)
    return
  end
  local d = dict(conf)
  if d then
    -- shared dict value size limited; skip oversized vectors silently
    local ok, err = d:set("emb:" .. key, encoded, ttl)
    if not ok then
      kong.log.warn("ai-router semantic cache set failed: ", err)
    end
  end
end


function _M.extract_prompt(body, max_chars)
  max_chars = max_chars or 4000
  if type(body) ~= "table" then
    return ""
  end

  local parts = {}
  if type(body.messages) == "table" then
    -- prefer last user message(s); include recent context
    for i = #body.messages, 1, -1 do
      local m = body.messages[i]
      if type(m) == "table" and (m.role == "user" or m.role == "system") then
        local t = tools.content_to_text(m.content)
        if t and t ~= "" then
          parts[#parts + 1] = t
          if #parts >= 3 then
            break
          end
        end
      end
    end
    -- reverse to chronological
    local rev = {}
    for i = #parts, 1, -1 do
      rev[#rev + 1] = parts[i]
    end
    parts = rev
  elseif type(body.input) == "string" then
    parts[1] = body.input
  elseif type(body.prompt) == "string" then
    parts[1] = body.prompt
  elseif type(body.input) == "table" then
    -- embeddings-style input array
    for _, v in ipairs(body.input) do
      if type(v) == "string" then
        parts[#parts + 1] = v
      end
    end
  end

  local text = concat(parts, "\n")
  if #text > max_chars then
    text = text:sub(1, max_chars)
  end
  return text
end


function _M.cosine(a, b)
  if type(a) ~= "table" or type(b) ~= "table" or #a == 0 or #a ~= #b then
    return nil
  end
  local dot, na, nb = 0, 0, 0
  for i = 1, #a do
    local x = tonumber(a[i]) or 0
    local y = tonumber(b[i]) or 0
    dot = dot + x * y
    na = na + x * x
    nb = nb + y * y
  end
  if na <= 0 or nb <= 0 then
    return nil
  end
  return dot / (sqrt(na) * sqrt(nb))
end


local function embeddings_url(sem)
  local base = trim_slash(sem.api_base or "https://api.openai.com/v1")
  if base:find("/embeddings$") then
    return base
  end
  if base:find("/v1$") then
    return base .. "/embeddings"
  end
  return base .. "/embeddings"
end


--- Embed a single string; returns vector or nil, err
function _M.embed(conf, text)
  if type(text) ~= "string" or text == "" then
    return nil, "empty text"
  end

  local sem = conf.semantic or {}
  local cache_key = ngx.md5(tostring(sem.model or "text-embedding-3-small") .. "|" .. text)
  local cached = cache_get(conf, cache_key)
  if cached then
    return cached
  end

  local headers = {
    ["Content-Type"] = "application/json",
    ["Accept"] = "application/json",
  }
  if sem.api_key and sem.api_key ~= "" then
    headers["Authorization"] = "Bearer " .. sem.api_key
  end
  if type(sem.extra_headers) == "table" then
    for k, v in pairs(sem.extra_headers) do
      headers[k] = tostring(v)
    end
  end

  local payload = cjson.encode({
    model = sem.model or "text-embedding-3-small",
    input = text,
  })
  if not payload then
    return nil, "encode embeddings request failed"
  end

  local status, _, body, err = http_client.request({
    url = embeddings_url(sem),
    method = "POST",
    headers = headers,
    body = payload,
  }, {
    connect = conf.connect_timeout or 2000,
    send = conf.send_timeout or 10000,
    read = sem.timeout or 5000,
  }, {
    keepalive_timeout = conf.keepalive_timeout or 60000,
    keepalive_pool_size = conf.keepalive_pool_size or 128,
    ssl_verify = conf.ssl_verify ~= false,
  })

  if not status then
    return nil, err or "embeddings request failed"
  end
  if status < 200 or status >= 300 then
    return nil, "embeddings status " .. tostring(status) .. ": " .. tostring(body)
  end

  local obj = cjson.decode(body)
  local vec = obj and obj.data and obj.data[1] and obj.data[1].embedding
  if type(vec) ~= "table" or #vec == 0 then
    return nil, "invalid embeddings response"
  end

  cache_set(conf, cache_key, vec, sem.cache_ttl or 86400)
  return vec
end


function _M.description_of(dep)
  if type(dep) ~= "table" then
    return nil
  end
  if type(dep.description) == "string" and dep.description ~= "" then
    return dep.description
  end
  local info = dep.model_info
  if type(info) == "table" and type(info.description) == "string" and info.description ~= "" then
    return info.description
  end
  return nil
end


function _M.is_catch_all(dep)
  if not dep then
    return false
  end
  if dep.catch_all == true or dep.catch_all == "true" then
    return true
  end
  local info = dep.model_info
  return type(info) == "table" and (info.catch_all == "true" or info.catch_all == "1")
end


--- Rank candidates by similarity to prompt_vec.
--- Returns sorted list { dep, score }, best first; catch_all entries score as -inf unless no match.
function _M.rank(conf, candidates, prompt_vec)
  local threshold = tonumber((conf.semantic or {}).threshold) or 0
  local scored = {}
  local catch_alls = {}

  for i = 1, #candidates do
    local dep = candidates[i]
    if _M.is_catch_all(dep) then
      catch_alls[#catch_alls + 1] = dep
    else
      local desc = _M.description_of(dep)
      if desc then
        local dvec, err = _M.embed(conf, desc)
        if dvec then
          local score = _M.cosine(prompt_vec, dvec)
          if score and score >= threshold then
            scored[#scored + 1] = { dep = dep, score = score }
          end
        else
          kong.log.warn("ai-router semantic embed description failed: ", err)
        end
      end
    end
  end

  sort(scored, function(a, b)
    return a.score > b.score
  end)

  if #scored == 0 then
    -- fall back to catch-all deployments
    local out = {}
    for i = 1, #catch_alls do
      out[#out + 1] = { dep = catch_alls[i], score = 0 }
    end
    return out
  end

  return scored
end


function _M.pick_best(conf, candidates, prompt_vec)
  local ranked = _M.rank(conf, candidates, prompt_vec)
  if #ranked == 0 then
    return nil, nil
  end
  return ranked[1].dep, ranked[1].score
end


--- Cross-model: pick best model_name (and preferred deployment) from full model_list.
function _M.resolve_model(conf, model_list, prompt_text, allow_fn)
  local prompt_vec, err = _M.embed(conf, prompt_text)
  if not prompt_vec then
    return nil, nil, err
  end

  local candidates = {}
  for i = 1, #(model_list or {}) do
    local entry = model_list[i]
    if entry and entry.model_name then
      if not allow_fn or allow_fn(entry.model_name) then
        -- skip the selector virtual name itself
        local sel = (conf.semantic and conf.semantic.selector_model) or "auto"
        if entry.model_name ~= sel then
          candidates[#candidates + 1] = entry
        end
      end
    end
  end

  local dep, score = _M.pick_best(conf, candidates, prompt_vec)
  if not dep then
    local fallback = conf.semantic and conf.semantic.catch_all_model
    if fallback and fallback ~= "" then
      return fallback, nil, nil, prompt_vec
    end
    return nil, nil, "no semantic match above threshold"
  end
  return dep.model_name, score, nil, prompt_vec, dep
end


function _M.is_selector(conf, model)
  local sel = (conf.semantic and conf.semantic.selector_model) or "auto"
  return model == sel or model == "semantic"
end


return _M
