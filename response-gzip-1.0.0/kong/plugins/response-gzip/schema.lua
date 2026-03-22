local typedefs = require "kong.db.schema.typedefs"

-- text/event-stream（SSE）为长连接流式响应，与本插件「缓冲整包再 gzip」机制不兼容
local function validate_content_types(value)
  if type(value) ~= "table" then
    return true
  end
  for _, item in ipairs(value) do
    if type(item) == "string" then
      local s = item:lower():match("^%s*(.-)%s*$") or ""
      if s == "text/event-stream" then
        return nil, "content_types must not include text/event-stream (SSE is incompatible with this plugin)"
      end
    end
  end
  return true
end

return {
  name = "response-gzip",
  fields = {
    { protocols = typedefs.protocols },
    {
      config = {
        type = "record",
        fields = {
          {
            min_length = {
              description = "仅当响应体字节数不小于此值时才进行 gzip 压缩，避免小响应压缩后更大。0 表示不限制。",
              type = "integer",
              required = false,
              default = 256,
            },
          },
          {
            content_types = {
              description = "仅对这些 Content-Type 的响应进行压缩（前缀匹配，如 application/json）。空数组表示不按类型过滤，全部压缩。禁止包含 text/event-stream（SSE 流式与本插件不兼容）。",
              type = "array",
              elements = { type = "string" },
              required = false,
              default = {},
              custom_validator = validate_content_types,
            },
          },
          {
            compression_level = {
              description = "gzip 压缩级别 1-9，1 最快，9 压缩率最高。",
              type = "integer",
              required = false,
              default = 6,
              between = { 1, 9 },
            },
          },
        },
      },
    },
  },
}
