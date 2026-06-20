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
local ceil         = math.ceil
local concat       = table.concat


local _M = {}

-- 超过此大小（字节）的 JSON 将拆分为多个文件存储；可通过 opts.chunk_size 覆盖
local DEFAULT_CHUNK_SIZE = 5242880  -- 5 MiB

-- 尝试加载 LuaFileSystem，用于目录遍历（flush 操作）
local lfs_ok, lfs = pcall(require, "lfs")


--- 将缓存键转换为安全的文件名前缀（作为文件路径组件）
-- @string key 缓存键
-- @return 安全文件名前缀（MD5 哈希值）
local function key_to_filename(key)
  return ngx.md5(key)
end


--- 根据 key 的前缀在目录中查找缓存主文件（支持格式：{md5} 或 {md5}_{expiry_ts}；排除 .chunk.N 分片文件）
-- @string path 目录路径
-- @string key_base key_to_filename(key) 的结果
-- @return 找到则返回完整 filepath，否则返回 nil
local function find_cache_meta_filepath(path, key_base)
  if not lfs_ok then
    return nil
  end
  local prefix = key_base .. "_"
  for name in lfs.dir(path) do
    if name ~= "." and name ~= ".." then
      if name == key_base then
        return path .. "/" .. name
      end
      if name:sub(1, #prefix) == prefix and not name:find("%.chunk%.", 1, true) then
        return path .. "/" .. name
      end
    end
  end
  return nil
end


--- 列出同一 cache key 对应的所有文件（主文件 + 分片）
local function list_cache_files(path, key_base)
  local files = {}
  if not lfs_ok then
    return files
  end
  local prefix = key_base .. "_"
  for name in lfs.dir(path) do
    if name ~= "." and name ~= ".." then
      if name == key_base or name:sub(1, #prefix) == prefix then
        files[#files + 1] = path .. "/" .. name
      end
    end
  end
  return files
end


local function delete_cache_files(path, key_base)
  local files = list_cache_files(path, key_base)
  for i = 1, #files do
    remove(files[i])
  end
  return true
end


local function get_chunk_size(opts)
  local size = opts.chunk_size
  if size == nil then
    return DEFAULT_CHUNK_SIZE
  end
  if size <= 0 then
    return nil
  end
  return size
end


local function is_chunked_meta(val)
  if type(val) ~= "table" then
    return false
  end
  return val.__pca_chunked == true
    and type(val.chunks) == "number"
    and val.chunks > 0
end


local function build_chunk_filepath(meta_filepath, index)
  return meta_filepath .. ".chunk." .. index
end


local function chunk_file_exists(chunk_path)
  local f = open(chunk_path, "r")
  if not f then
    return false
  end
  f:close()
  return true
end


--- 校验 meta.chunks 声明的全部分片文件是否均存在
local function verify_chunk_files_complete(meta_filepath, num_chunks)
  for i = 0, num_chunks - 1 do
    if not chunk_file_exists(build_chunk_filepath(meta_filepath, i)) then
      return false
    end
  end
  return true
end


local function write_file(filepath, content)
  local f, err_open = open(filepath, "w")
  if not f then
    return nil, "failed to open file for writing: " .. tostring(err_open)
  end

  local ok_write = f:write(content)
  if not ok_write then
    f:close()
    remove(filepath)
    return nil, "failed to write cache file"
  end

  local flush_ok, flush_err = f:flush()
  f:close()

  if not flush_ok and ngx and ngx.log then
    ngx.log(ngx.WARN, "cache file written but flush failed: ", tostring(flush_err))
  end

  return true
end


local function read_file(filepath)
  local f, err = open(filepath, "r")
  if not f then
    return nil, err
  end

  local content = f:read("*a")
  f:close()
  return content
end


local function store_chunked(meta_filepath, req_json, chunk_size)
  local total_len = #req_json
  local num_chunks = ceil(total_len / chunk_size)
  local written_chunks = {}

  for i = 0, num_chunks - 1 do
    local start = i * chunk_size + 1
    local chunk = req_json:sub(start, start + chunk_size - 1)
    local chunk_path = build_chunk_filepath(meta_filepath, i)
    local ok, err = write_file(chunk_path, chunk)
    if not ok then
      for j = 1, #written_chunks do
        remove(written_chunks[j])
      end
      return nil, err
    end
    written_chunks[#written_chunks + 1] = chunk_path
  end

  local meta_json = cjson.encode({
    __pca_chunked = true,
    chunks = num_chunks,
  })
  if not meta_json then
    for i = 1, #written_chunks do
      remove(written_chunks[i])
    end
    return nil, "could not encode chunk metadata"
  end

  local ok, err = write_file(meta_filepath, meta_json)
  if not ok then
    for i = 1, #written_chunks do
      remove(written_chunks[i])
    end
    return nil, err
  end

  return true
end


local function fetch_chunked(meta_filepath, meta, path, key_base)
  if not verify_chunk_files_complete(meta_filepath, meta.chunks) then
    if path and key_base then
      delete_cache_files(path, key_base)
    end
    return nil, "request object not in cache"
  end

  local parts = {}
  for i = 0, meta.chunks - 1 do
    local chunk_path = build_chunk_filepath(meta_filepath, i)
    local chunk, err = read_file(chunk_path)
    if not chunk or chunk == "" then
      if path and key_base then
        delete_cache_files(path, key_base)
      end
      return nil, "request object not in cache"
    end
    if err then
      return nil, "failed to read cache chunk file: " .. tostring(err)
    end
    parts[#parts + 1] = chunk
  end

  local req_json = concat(parts)
  local req_obj = cjson.decode(req_json)
  if not req_obj then
    if path and key_base then
      delete_cache_files(path, key_base)
    end
    return nil, "request object not in cache"
  end

  return req_obj
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

  -- 文件名包含过期截止时间：{md5}_{expiry_ts}，便于按文件清理与排查
  local key_base = key_to_filename(key)
  local req_ttl_sec = (type(req_ttl) == "number" and req_ttl > 0) and req_ttl or 3600
  local expiry_ts = time() + req_ttl_sec
  local filename = key_base .. "_" .. tostring(expiry_ts)
  -- 删除同 key 的旧文件（单文件 / 分片格式），避免同一 key 多文件
  delete_cache_files(path, key_base)
  local filepath = path .. "/" .. filename

  local chunk_size = get_chunk_size(self.opts)
  local use_chunks = chunk_size and #req_json > chunk_size

  if use_chunks then
    local ok_store, err_store = store_chunked(filepath, req_json, chunk_size)
    if not ok_store then
      delete_cache_files(path, key_base)
      return nil, err_store
    end
    return true, req_json
  end

  local ok_write, err_write = write_file(filepath, req_json)
  if not ok_write then
    return nil, err_write
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

  local path = self.opts.path
  local key_base = key_to_filename(key)
  local filepath = find_cache_meta_filepath(path, key_base) or (path .. "/" .. key_base)
  local req_json, err = read_file(filepath)
  if not req_json then
    local err_str = tostring(err or "")
    if err_str:find("No such file") or err_str:find("not found") or err_str:find("does not exist") then
      return nil, "request object not in cache"
    end
    return nil, "failed to open cache file: " .. err_str
  end

  if req_json == "" then
    return nil, "request object not in cache"
  end

  local meta = cjson.decode(req_json)
  local req_obj
  if is_chunked_meta(meta) then
    req_obj, err = fetch_chunked(filepath, meta, path, key_base)
    if not req_obj then
      return nil, err
    end
  else
    req_obj = meta
    if not req_obj then
      delete_cache_files(path, key_base)
      return nil, "request object not in cache"
    end
  end

  -- 检查 TTL 是否已过期
  local ttl = req_obj.ttl or 0
  if ttl > 0 and (time() - (req_obj.timestamp or 0)) > ttl then
    delete_cache_files(path, key_base)
    return nil, "request object not in cache"
  end

  return req_obj
end


--- 从请求缓存中清除指定条目
function _M:purge(key)
  if type(key) ~= "string" then
    return nil, "key must be a string"
  end

  local path = self.opts.path
  local key_base = key_to_filename(key)
  delete_cache_files(path, key_base)

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
