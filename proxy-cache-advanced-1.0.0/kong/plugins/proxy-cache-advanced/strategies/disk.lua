---
--- proxy-cache-advanced 的磁盘存储策略
---
local cjson = require "cjson.safe"


local ngx          = ngx
local type         = type
local time         = ngx.time
local setmetatable = setmetatable
local open         = io.open
local remove       = os.remove
local match        = string.match
local sub          = string.sub


local _M = {}

-- 尝试加载 LuaFileSystem，用于目录遍历（flush 操作）
local lfs_ok, lfs = pcall(require, "lfs")


--- 将缓存键转换为安全的文件名（作为文件路径组件）
-- @string key 缓存键
-- @return 安全文件名（MD5 哈希值）
local function key_to_filename(key)
  return ngx.md5(key)
end


--- 确保目录存在，若不存在则创建（递归创建）
-- @string path 目录路径
-- @return 成功返回 true，失败返回 nil 和错误信息
local function ensure_dir(path)
  if not lfs_ok then
    return nil, "lua-filesystem (lfs) required for disk strategy"
  end
  local attr, err = lfs.attributes(path)
  if attr then
    if attr.mode == "directory" then
      return true
    end
    return nil, "path exists but is not a directory: " .. path
  end
  -- 若路径包含多级目录，先递归创建父目录
  local parent = match(path, "^(.+)/[^/]+$")
  if parent and parent ~= "" and parent ~= path then
    local ok_p, err_p = ensure_dir(parent)
    if not ok_p then
      return nil, err_p
    end
  end
  local ok_create, err_create = lfs.mkdir(path)
  if not ok_create then
    return nil, "failed to create directory: " .. tostring(err_create)
  end
  return true
end


--- 创建新的磁盘策略对象
-- @table opts 策略选项：path（必填）
function _M.new(opts)
  if not opts then
    return nil, "disk options are required"
  end

  if not opts.path or opts.path == "" then
    return nil, "disk.path is required"
  end

  -- 校验路径：仅允许字母、数字、斜杠、点、连字符、下划线
  if not match(opts.path, "^[a-zA-Z0-9/_.%-]+$") then
    return nil, "disk.path contains invalid characters"
  end

  -- 禁止路径穿越
  if match(opts.path, "%.%.") then
    return nil, "disk.path must not contain '..'"
  end

  local self = {
    opts = opts,
  }

  return setmetatable(self, {
    __index = _M,
  })
end


--- 将请求实体存储到磁盘
-- @string key 请求键
-- @table req_obj 请求对象
-- @int[opt] req_ttl 请求的 TTL（秒）
function _M:store(key, req_obj, req_ttl)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  local req_json = cjson.encode(req_obj)
  if not req_json then
    return nil, "could not encode request object"
  end

  local path = self.opts.path

  -- 确保目录存在，若不存在则创建
  local ok, err = ensure_dir(path)
  if not ok then
    return nil, "failed to ensure cache directory exists: " .. tostring(err)
  end

  -- 写入文件前再次确认目录存在
  if lfs_ok then
    local attr, attr_err = lfs.attributes(path)
    if not attr or attr.mode ~= "directory" then
      return nil, "cache directory does not exist or is not a directory: " .. path
    end
  end

  local filename = key_to_filename(key)
  local filepath = path .. "/" .. filename

  -- 以写模式打开文件（若不存在则创建）
  local f, err_open = open(filepath, "w")
  if not f then
    -- 若打开失败，再次确保目录存在并重试一次
    local retry_ok, retry_err = ensure_dir(path)
    if retry_ok then
      f, err_open = open(filepath, "w")
      if not f then
        return nil, "failed to open file for writing after directory creation: " .. tostring(err_open)
      end
    else
      return nil, "failed to open file for writing: " .. tostring(err_open) .. " (directory check: " .. tostring(retry_err) .. ")"
    end
  end

  local ok_write = f:write(req_json)
  if not ok_write then
    f:close()
    -- 若写入失败，删除不完整文件
    remove(filepath)
    return nil, "failed to write cache file"
  end

  -- 刷新缓冲区，确保数据写入磁盘
  local flush_ok, flush_err = f:flush()
  f:close()

  if not flush_ok then
    -- 写入成功但刷新失败，仍视为成功，仅记录日志便于调试
    if ngx and ngx.log then
      ngx.log(ngx.WARN, "cache file written but flush failed: ", tostring(flush_err))
    end
  end

  return true, req_json
end


--- 从磁盘获取缓存的请求
-- @string key 请求键
-- @return 表示请求的表
function _M:fetch(key)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  local filepath = self.opts.path .. "/" .. key_to_filename(key)
  local f, err = open(filepath, "r")
  if not f then
    -- 判断是否为文件不存在的错误（缓存未命中属正常情况）
    -- 错误格式可能为："No such file or directory" 或 "path: No such file or directory"
    local err_str = tostring(err or "")
    if err_str:find("No such file") or err_str:find("not found") or err_str:find("does not exist") then
      return nil, "request object not in cache"
    end
    return nil, "failed to open cache file: " .. err_str
  end

  local req_json = f:read("*a")
  f:close()

  if not req_json or req_json == "" then
    return nil, "request object not in cache"
  end

  local req_obj = cjson.decode(req_json)
  if not req_obj then
    return nil, "could not decode request object"
  end

  -- 检查 TTL 是否已过期
  local ttl = req_obj.ttl or 0
  if ttl > 0 and (time() - (req_obj.timestamp or 0)) > ttl then
    remove(filepath)
    return nil, "request object not in cache"
  end

  return req_obj
end


--- 从请求缓存中清除指定条目
function _M:purge(key)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  local filepath = self.opts.path .. "/" .. key_to_filename(key)
  local ok, err = remove(filepath)
  if not ok and err then
    -- 若文件不存在，仍视为 purge 成功（幂等性）
    local err_str = tostring(err)
    if not (err_str:find("No such file") or err_str:find("not found") or err_str:find("does not exist")) then
      return nil, "failed to remove cache file: " .. err_str
    end
  end

  return true
end


--- 重置缓存请求的 TTL
function _M:touch(key, req_ttl, timestamp)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  local req_obj, err = self:fetch(key)
  if not req_obj then
    return nil, err or "request object not in cache"
  end

  req_obj.timestamp = timestamp or time()

  return self:store(key, req_obj, req_ttl)
end


--- 移除所有缓存条目
-- @param free_mem 布尔值（磁盘策略忽略；保留以兼容 API）
function _M:flush(free_mem)
  if not lfs_ok then
    return nil, "lua-filesystem (lfs) required for disk strategy flush"
  end

  local path = self.opts.path
  local attr, err = lfs.attributes(path)
  if not attr then
    -- 若目录不存在，仍视为 flush 成功（无需清理）
    local err_str = tostring(err or "")
    if err_str:find("No such file") or err_str:find("not found") or err_str:find("does not exist") then
      return true
    end
    return nil, "failed to access cache directory: " .. err_str
  end

  if attr.mode ~= "directory" then
    return nil, "cache path is not a directory"
  end

  for name in lfs.dir(path) do
    if name ~= "." and name ~= ".." then
      local filepath = path .. "/" .. name
      local file_attr = lfs.attributes(filepath)
      if file_attr and file_attr.mode == "file" then
        remove(filepath)
      end
    end
  end

  return true
end


return _M
