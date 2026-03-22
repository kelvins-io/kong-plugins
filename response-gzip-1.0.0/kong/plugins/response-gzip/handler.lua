--
-- Kong 插件：将上游响应 body 进行 gzip 压缩后返回给客户端。
-- 在 header_filter 中设置 Content-Encoding: gzip，在 body_filter 中压缩完整 body 并替换。
--
-- 说明：Nginx 在 body_filter 阶段无法修改下游响应头；若 header 已声明 gzip，则无法在
-- body_filter 中安全撤销 Content-Encoding。因此 min_length 仅在「上游带 Content-Length」
-- 时在 header_filter 中生效；无 Content-Length 时仍可能压缩极小 body（略增大体积）。
-- 上游 Content-Type 为 text/event-stream（SSE）时始终跳过压缩，与 content_types 是否为空无关。
--
local kong = kong

local ResponseGzipHandler = {
  PRIORITY = 900,
  VERSION = "1.0.0",
}

local CTX_KEY = "response_gzip_compress"

-- 模块级缓存：nil=未探测，false=无可用库，function=压缩函数
local cached_deflater

-- 获取 gzip 压缩函数（优先使用 Kong 内置 kong.tools.gzip，否则尝试 ffi-zlib）
local function get_gzip_deflater()
  if cached_deflater ~= nil then
    return cached_deflater ~= false and cached_deflater or nil
  end
  local ok, gzip = pcall(require, "kong.tools.gzip")
  if ok and gzip and gzip.deflate_gzip then
    cached_deflater = function(data, level)
      local opts = (level and level >= 1 and level <= 9) and { level = level } or nil
      return gzip.deflate_gzip(data, opts)
    end
    return cached_deflater
  end
  local ok_z, zlib = pcall(require, "zlib")
  if not (ok_z and zlib and zlib.deflateGzip) then
    ok_z, zlib = pcall(require, "ffi-zlib")
  end
  if ok_z and zlib and zlib.deflateGzip then
    cached_deflater = function(data, level)
      local lvl = level
      if type(lvl) ~= "number" or lvl < 1 or lvl > 9 then
        lvl = 6
      end
      local pos = 1
      local function input(size)
        if pos > #data then return nil end
        local chunk = data:sub(pos, math.min(pos + size - 1, #data))
        pos = pos + #chunk
        return chunk
      end
      local out = {}
      local function output(c) out[#out + 1] = c end
      local ok2, err = zlib.deflateGzip(input, output, nil, { level = lvl })
      if not ok2 then return nil, err end
      return table.concat(out)
    end
    return cached_deflater
  end
  cached_deflater = false
  return nil
end

-- 上游（Service）响应是否已带压缩类 Content-Encoding
local function upstream_already_encoded()
  local enc = kong.service.response.get_header("Content-Encoding")
  if not enc then return false end
  enc = enc:lower()
  return not not (enc:find("gzip", 1, true) or enc:find("deflate", 1, true) or enc:find("br", 1, true))
end

-- 仅取 Content-Type 主类型（去掉 ; 后参数），用于前缀匹配
local function primary_content_type()
  local ct = kong.service.response.get_header("Content-Type")
  if not ct then return nil end
  local semi = ct:find(";", 1, true)
  if semi then
    ct = ct:sub(1, semi - 1)
  end
  return ct:match("^%s*(.-)%s*$")
end

-- SSE 流式响应与本插件整包缓冲 gzip 不兼容，始终不处理
local function is_text_event_stream()
  local ct = primary_content_type()
  if not ct then return false end
  return ct:lower() == "text/event-stream"
end

local function content_type_matches(conf)
  local types = conf.content_types
  if not types or #types == 0 then
    return true
  end
  local ct = primary_content_type()
  if not ct then return false end
  ct = ct:lower()
  for _, prefix in ipairs(types) do
    if type(prefix) == "string" and prefix ~= "" then
      local p = prefix:lower()
      if ct:sub(1, #p) == p then
        return true
      end
    end
  end
  return false
end

-- 在 header_filter：若上游明确 Content-Length 且小于 min_length，则跳过（不声明 gzip）
local function skip_by_header_content_length(conf)
  local min_len = conf.min_length or 0
  if min_len <= 0 then return false end
  local cl = kong.service.response.get_header("Content-Length")
  if not cl then return false end
  local n = tonumber(cl)
  if not n then return false end
  return n < min_len
end

function ResponseGzipHandler:header_filter(conf)
  if upstream_already_encoded() then
    return
  end
  if is_text_event_stream() then
    return
  end
  if not content_type_matches(conf) then
    return
  end
  if skip_by_header_content_length(conf) then
    return
  end
  if not get_gzip_deflater() then
    kong.log.err("response-gzip: no gzip library available (kong.tools.gzip or zlib)")
    return
  end

  kong.ctx.plugin[CTX_KEY] = true
  kong.response.clear_header("Content-Length")
  kong.response.set_header("Content-Encoding", "gzip")
end

function ResponseGzipHandler:body_filter(conf)
  if not kong.ctx.plugin[CTX_KEY] then
    return
  end

  local body = kong.response.get_raw_body()
  if not body then
    return
  end

  local level = conf.compression_level or 6
  if type(level) ~= "number" or level < 1 or level > 9 then
    level = 6
  end

  local deflate = get_gzip_deflater()
  if not deflate then
    kong.log.err("response-gzip: gzip library disappeared at runtime")
    kong.response.set_raw_body(body)
    kong.ctx.plugin[CTX_KEY] = nil
    return
  end

  local compressed, err = deflate(body, level)
  if not compressed then
    kong.log.err("response-gzip: compress failed: ", err)
    kong.response.set_raw_body(body)
    kong.ctx.plugin[CTX_KEY] = nil
    return
  end

  kong.response.set_raw_body(compressed)
  kong.ctx.plugin[CTX_KEY] = nil
end

return ResponseGzipHandler
