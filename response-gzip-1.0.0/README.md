# response-gzip

Kong 插件：将上游响应 body 进行 gzip 压缩后返回给客户端。

## 行为说明

- 上游响应 `Content-Type` 主类型为 **`text/event-stream`（SSE）时不压缩**，与 `content_types` 是否配置无关。
- 仅当**上游 Service 响应**尚未声明 `Content-Encoding`（或非 gzip/deflate/br）时压缩；判断使用 `kong.service.response`，避免与下游已设置的 `Content-Encoding` 混淆。
- 在 `header_filter` 中通过 `kong.ctx.plugin` 标记待压缩，设置 `Content-Encoding: gzip` 并清除 `Content-Length`。
- 在 `body_filter` 阶段在**最后一个 chunk** 调用 `kong.response.get_raw_body()` 取全量 body，压缩后 `set_raw_body`。
- `min_length`：仅在**上游响应带有 `Content-Length`** 时在 `header_filter` 中判断；过小则**不**声明 gzip。无 `Content-Length`（如 chunked）时无法在发头前得知长度，仍会声明 gzip；极小 body 可能被压缩后略大。
- 在 `header_filter` 中探测 gzip 库；若无可用库则不声明 gzip。若在 `body_filter` 中压缩失败，会回写原始 body，但**无法**在 `body_filter` 中撤销已发送的 `Content-Encoding`（Nginx 限制），客户端可能解压失败；应通过日志与监控处理。

## 依赖

- 优先使用 Kong 内置的 `kong.tools.gzip`（Kong 3.x 常见）。
- 若不存在则尝试 `require "zlib"`（如通过 `luarocks install kong-lua-ffi-zlib` 安装）。

## 配置

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `min_length` | integer | 256 | 仅当 body 字节数 ≥ 此值时才压缩；0 表示不限制。若上游**有** `Content-Length` 且数值小于该值，则在 `header_filter` 跳过压缩。无 `Content-Length` 时不在此处生效（见上文）。 |
| `content_types` | array of string | [] | 非空时仅对 **Content-Type 主类型**（`;` 前）做**前缀匹配**（大小写不敏感）；空数组表示不限制。schema 禁止写入 `text/event-stream`；handler 对上游 SSE 仍会直接跳过。 |
| `compression_level` | integer | 6 | gzip 级别 1–9（schema 校验）。 |

## 安装

```bash
luarocks install response-gzip-1.0.0-1.rockspec
```

或复制 `kong/plugins/response-gzip/` 到 Kong 的 plugins 目录，并在 `kong.conf` 的 `plugins` 中加入 `response-gzip`。

## 使用示例

对某 Route 或 Service 启用：

```yaml
plugins:
  - name: response-gzip
    config:
      compression_level: 6
```

建议客户端在请求中携带 `Accept-Encoding: gzip`；本插件不强制校验该头，未携带时仍可能返回 gzip 体（取决于客户端与中间层行为）。
