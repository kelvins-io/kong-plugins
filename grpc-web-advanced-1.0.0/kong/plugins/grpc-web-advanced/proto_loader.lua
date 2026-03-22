---
--- 解析 conf.proto：当为远程 URL（http/https）时拉取并缓存到本地，返回本地文件路径。
--- 本地路径直接返回。
---

local http = require "resty.http"
local lfs = require "lfs"
local kong = kong
local sub = string.sub
local format = string.format
local gsub = string.gsub
local match = string.match


-- 默认缓存目录（可被 schema 中的 proto_cache_dir 覆盖）
local DEFAULT_CACHE_DIR = "/usr/local/kong/tmp/proto_cache"
local DEFAULT_HTTP_TIMEOUT_MS = 10000

local _M = {}

-- 判断是否为远程 URL
local function is_remote_url(proto)
  if type(proto) ~= "string" or proto == "" then
    return false
  end
  local lower = proto:lower()
  return sub(lower, 1, 7) == "http://" or sub(lower, 1, 8) == "https://"
end

-- 从 URL 得到安全的缓存文件名（避免路径注入）
local function url_to_cache_basename(url)
  local hash = ngx.md5(url)
  local name = match(url, "([^/]+)%.proto$")
  if name then
    name = gsub(name, "[^%w%.%-_]", "_")
    return hash .. "_" .. name .. ".proto"
  end
  return hash .. ".proto"
end

-- 确保目录存在
local function ensure_dir(path)
  local ok, err = lfs.mkdir(path)
  if ok then
    return true
  end
  if err == "File exists" then
    local attr = lfs.attributes(path)
    return attr and attr.mode == "directory"
  end
  return nil, err
end

--- 获取缓存根目录：使用配置项或默认路径
local function get_cache_root(conf)
  local root = conf and conf.proto_cache_dir
  if type(root) == "string" and root ~= "" then
    return root
  end
  return DEFAULT_CACHE_DIR
end

--- 从远程 URL 拉取内容并写入缓存文件
local function fetch_and_cache(url, cache_path, timeout_ms, ssl_verify)
  timeout_ms = timeout_ms or DEFAULT_HTTP_TIMEOUT_MS
  if ssl_verify == nil then
    ssl_verify = true
  end
  local httpc = http:new()
  if not httpc then
    return nil, "failed to create http client"
  end
  httpc:set_timeout(timeout_ms)

  local res, err = httpc:request_uri(url, {
    method = "GET",
    ssl_verify = ssl_verify,
  })

  if err then
    return nil, "fetch proto failed: " .. tostring(err)
  end
  if not res then
    return nil, "fetch proto: no response"
  end
  if res.status ~= 200 then
    return nil, format("fetch proto: HTTP %s", tostring(res.status))
  end

  local body = res.body
  if not body or #body == 0 then
    return nil, "fetch proto: empty body"
  end

  local file, err = io.open(cache_path, "wb")
  if not file then
    return nil, "write cache failed: " .. tostring(err)
  end
  file:write(body)
  file:close()
  return cache_path
end

---
--- 解析 proto 配置，返回可供 grpc_tools 使用的本地文件路径。
--- @param proto string 本地路径或远程 URL（http/https）
--- @param conf table 插件配置（可选，用于 proto_cache_dir / proto_fetch_timeout / proto_fetch_ssl_verify）
--- @return string|nil 本地 .proto 文件路径
--- @return string|nil 失败时的错误信息
---
function _M.resolve_proto(proto, conf)
  if not proto or type(proto) ~= "string" or proto == "" then
    return nil
  end

  if not is_remote_url(proto) then
    return proto
  end

  local root = get_cache_root(conf)
  local ok, err = ensure_dir(root)
  if not ok then
    return nil, "proto cache dir: " .. tostring(err)
  end

  local basename = url_to_cache_basename(proto)
  local cache_path = root .. "/" .. basename

  local timeout_ms = (conf and conf.proto_fetch_timeout and conf.proto_fetch_timeout > 0)
    and (conf.proto_fetch_timeout * 1000)
    or DEFAULT_HTTP_TIMEOUT_MS

  local ssl_verify = true
  if conf and conf.proto_fetch_ssl_verify ~= nil then
    ssl_verify = conf.proto_fetch_ssl_verify
  end

  -- 若缓存文件已存在则直接使用（不在此处做 TTL 过期，由上层或运维清理缓存目录）
  local attr = lfs.attributes(cache_path)
  if attr and attr.mode == "file" then
    return cache_path
  end

  return fetch_and_cache(proto, cache_path, timeout_ms, ssl_verify)
end

---
--- 获取缓存根目录（供 api 等外部调用）
--- @param conf table 插件配置
--- @return string 缓存目录路径
---
function _M.get_cache_root(conf)
  return get_cache_root(conf)
end

---
--- 清空指定目录下的所有 .proto 缓存文件
--- @param cache_dir string 缓存目录路径
--- @return number|nil 删除的文件数量
--- @return string|nil 失败时的错误信息
---
function _M.purge_cache_dir(cache_dir)
  if not cache_dir or type(cache_dir) ~= "string" or cache_dir == "" then
    return nil, "invalid cache_dir"
  end

  local attr = lfs.attributes(cache_dir)
  if not attr then
    return 0, nil  -- 目录不存在，视为已清空
  end
  if attr.mode ~= "directory" then
    return nil, "cache_dir is not a directory"
  end

  local count = 0
  for name in lfs.dir(cache_dir) do
    if name ~= "." and name ~= ".." then
      local path = cache_dir .. "/" .. name
      local fattr = lfs.attributes(path)
      if fattr and fattr.mode == "file" and match(name, "%.proto$") then
        local ok, err = os.remove(path)
        if ok then
          count = count + 1
        else
          return count, "failed to remove " .. path .. ": " .. tostring(err)
        end
      end
    end
  end
  return count, nil
end

return _M
