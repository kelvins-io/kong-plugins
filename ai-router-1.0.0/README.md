# ai-router

Kong 插件：对齐 [LiteLLM Router](https://docs.litellm.ai/docs/routing) 的模型别名路由、负载均衡、重试、冷却、Fallback、虚拟 Key / 预算，以及多厂商协议转换。

在 `access` 阶段直连 Provider 并短路 Kong Service 上游；客户端保持 **OpenAI 兼容** API。

## 功能一览

| 能力 | 说明 |
|------|------|
| model 别名 + 同组 LB | `model_list`；同别名多部署按 `order` / 策略选路 |
| 路由策略 | `simple-shuffle` / `least-busy` / `latency-based-routing` / `cost-based-routing` / `usage-based-routing` / `semantic` |
| 语义路由 | `routing_strategy=semantic` 或 `model=auto`：按 prompt 与 `description` 的 embedding 相似度选模型 |
| 重试 / 冷却 / order | `num_retries`、`allowed_fails`、`cooldown_time`；部署 `order` 越小越优先 |
| Fallback | 通用 `fallbacks` / `default_fallbacks`；专用 `context_window_fallbacks` / `content_policy_fallbacks` |
| 请求级 fallback 链 | body `fallbacks` / `models` / `disable_fallbacks`（覆盖静态配置） |
| Provider | `openai` `azure` `anthropic` `bedrock` `gemini`；以及 `groq`/`mistral`/`deepseek`/`cohere`/`together`/`openrouter`/`fireworks`（OpenAI 兼容） |
| 端点 | `POST` chat/completions、completions、embeddings；可选 `GET /v1/models` |
| 跨节点状态 | `state_backend=redis`（cooldown / busy / latency / rpm·tpm / spend / embedding 缓存） |
| 虚拟 Key + 预算 | `enable_virtual_keys` / `virtual_keys` / `master_key`；**流式 SSE 收齐 usage 后扣费** |
| 工具调用透传 | OpenAI `tools`/`tool_calls` ↔ Anthropic / Bedrock / Gemini |

## 安装

```bash
cd ai-router-1.0.0 && luarocks make
```

```bash
KONG_PLUGINS=bundled,ai-router
# 建议专用 shdict（未配置时回退 kong）
# nginx: lua_shared_dict ai_router 10m;
```

## 支持的端点

| 方法 | 路径（可配 `path_patterns`） | 行为 |
|------|------------------------------|------|
| POST | `/v1/chat/completions`、`/chat/completions` | Chat Completions（含 stream） |
| POST | `/v1/completions`、`/completions` | Completions |
| POST | `/v1/embeddings`、`/embeddings` | Embeddings |
| GET/HEAD | `/v1/models`、`/models` | 列出已配置别名（需 `enable_models_endpoint`） |

匹配路径后由插件出站，**不再转发** Kong Service。

## 路由策略

同别名下多个部署先按 `litellm_params.order` 分组（越小越优先）；组内再按策略挑选：

| `routing_strategy` | 行为 |
|--------------------|------|
| `simple-shuffle`（默认） | 按 `weight`（或 `rpm` / `tpm` 推导权重）加权随机 |
| `least-busy` | 选当前 in-flight 请求最少的部署 |
| `latency-based-routing` | 选历史延迟最低的部署；无样本时先探索 |
| `cost-based-routing` | 选 `input_cost_per_token + output_cost_per_token` 最低的部署 |
| `usage-based-routing` | 优先远离 `rpm`/`tpm` 上限的部署；超限则跳过 |
| `semantic` | 按 prompt 与部署 `description` 的余弦相似度选；也可仅用 `model=auto` 做跨别名语义选择 |

冷却中的部署在 `enable_pre_call_checks=true`（默认）时不会被选中。

## 配置示例

```yaml
plugins:
  - name: ai-router
    config:
      routing_strategy: simple-shuffle
      num_retries: 2
      stream_num_retries: 1
      max_attempts: 8
      max_retry_backoff: 1000
      connect_timeout: 2000   # TCP/TLS 连接
      send_timeout: 10000     # 发送请求体
      timeout: 60000          # 读超时（流式为单次 read）
      keepalive_timeout: 60000
      keepalive_pool_size: 128
      state_cache_ttl: 1      # Redis 模式下 cooldown 本地缓存（秒）
      ssl_verify: true        # 上游 TLS 校验（生产建议开启）
      max_inflight: 200       # 0=不限制；超限 429
      allowed_fails: 3
      cooldown_time: 5
      state_backend: redis          # 或 local
      redis:
        host: redis
        port: 6379
        prefix: ai_router
        keepalive_timeout: 60000
        keepalive_pool_size: 128
      enable_models_endpoint: true
      enable_virtual_keys: true
      master_key: sk-master
      virtual_keys:
        - key: sk-team-a
          name: team-a
          models: ["gpt-4o", "claude-*"]
          max_budget: 10.0
      model_list:
        - model_name: gpt-4o
          litellm_params:
            model: openai/gpt-4o
            api_key: "sk-..."
            weight: 1
            order: 1
            input_cost_per_token: 0.0000025
            output_cost_per_token: 0.00001
        - model_name: gpt-4o          # 同别名第二部署 → LB
          litellm_params:
            model: azure/gpt-4o
            api_base: https://xxx.openai.azure.com
            api_key: "..."
            order: 1
            weight: 2
        - model_name: claude-sonnet
          litellm_params:
            model: anthropic/claude-3-5-sonnet-20241022
            api_key: "..."
        - model_name: bedrock-claude
          litellm_params:
            model: bedrock/us.anthropic.claude-sonnet-4-6
            api_key: "<bedrock-bearer-api-key>"
            aws_region_name: us-east-1
        - model_name: gemini-flash
          litellm_params:
            model: gemini/gemini-2.0-flash
            api_key: "AIza..."
      fallbacks:
        - model: gpt-4o
          fallbacks: ["claude-sonnet", "bedrock-claude"]
      context_window_fallbacks:
        - model: gpt-4o
          fallbacks: ["gpt-4o-long", "claude-sonnet"]
      content_policy_fallbacks:
        - model: gpt-4o
          fallbacks: ["claude-sonnet", "gemini-flash"]
```

### 专用 Fallback（对齐 LiteLLM）

| 配置 | 触发 | 行为 |
|------|------|------|
| `fallbacks` / `default_fallbacks` | 限流、超时、5xx、连接失败等 | 保可用性 |
| `context_window_fallbacks` | 上游报上下文超限 | 换更大窗口模型；**匹配到专用链后不再走通用 fallbacks** |
| `content_policy_fallbacks` | 内容审核 / safety filter 拦截 | 换策略不同的模型；匹配后同样不回落通用链 |

未配置对应专用规则时：上下文超限 / 内容策略错误会继续尝试同组剩余 order，再走通用 `fallbacks`。  
响应头：`x-ai-router-fallback-reason` = `context_window` / `content_policy` / `request`。

### 请求级 models 链（Client-Side Fallbacks）

在单次请求 body 里指定 fallback，**优先于**插件静态 `fallbacks`：

```bash
curl http://kong:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer sk-team-a' \
  -d '{
    "model": "gpt-4o",
    "messages": [{"role":"user","content":"hi"}],
    "fallbacks": ["claude-sonnet", "gemini-flash"]
  }'
```

也支持对象形式 `{"model":"claude-sonnet"}`，以及别名字段 `models: ["claude-sonnet"]`。  
本次禁用所有 fallback（含专用链）：`"disable_fallbacks": true`。  
这些字段只给路由器用，**不会**转发给上游 Provider。

### 语义路由

按 prompt 与各部署 `description` 的余弦相似度选模型（需配置 embeddings）：

```yaml
config:
  routing_strategy: semantic   # 组内按描述选部署；也可只用 model=auto
  semantic:
    api_base: https://api.openai.com/v1
    api_key: "sk-..."
    model: text-embedding-3-small
    threshold: 0.3
    selector_model: auto
    catch_all_model: general-chat
  model_list:
    - model_name: code-helper
      description: "Specialist in programming, debugging and code review"
      litellm_params: { model: openai/gpt-4o, api_key: "..." }
    - model_name: life-helper
      description: "Specialist in real life topics, travel and cooking"
      litellm_params: { model: openai/gpt-4o-mini, api_key: "..." }
    - model_name: general-chat
      catch_all: true
      description: "General purpose assistant"
      litellm_params: { model: openai/gpt-4o-mini, api_key: "..." }
```

```bash
curl http://kong:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"帮我重构这段 Python"}]}'
```

- `model=auto`（或 `semantic.selector_model`）：跨别名语义选择。
- `routing_strategy=semantic` 且指定具体别名：仅在该别名的多部署间按描述选路。
- 响应头：`x-ai-router-semantic-score`、`x-ai-router-model`（实际选中别名）。

### Provider 前缀

| `litellm_params.model` | 行为 |
|------------------------|------|
| `openai/<model>` | OpenAI / 任意兼容网关（可覆写 `api_base`） |
| `azure/<deployment>` | Azure OpenAI（**需** `api_base`） |
| `anthropic/<model>` | Anthropic Messages |
| `bedrock/<modelId>` | Bedrock Converse（Bearer API Key + `aws_region_name`） |
| `gemini/<model>` | Google generateContent |
| `groq/` `mistral/` `deepseek/` `cohere/` `together/` `openrouter/` `fireworks/` | OpenAI 兼容，内置默认 `api_base` |

别名：`claude/`→anthropic，`google/`/`vertex_ai/`→gemini，`together_ai/`/`fireworks_ai/` 等同 together/fireworks。

### 虚拟 Key

- 请求头：`Authorization: Bearer <key>` 或 `x-api-key`
- `master_key`：全模型、不扣预算
- `models`：允许列表，支持 `gpt-*` 尾缀通配；空=全部
- `max_budget`：累计 spend 超限返回 429；按部署 `input/output_cost_per_token` 扣费，缺省时用 Key 的 `token_cost`
- **原子扣费**：Redis 用 Lua `EVAL`（spend+cost 超限则拒绝）；local 用 shdict 短锁；并发下不会把 spend 加到超过 `max_budget`（已放行的 in-flight 请求仍可能完成上游调用）
- `blocked: true`：禁用该 Key（403）
- **流式**：OpenAI/Azure 自动补 `stream_options.include_usage`；SSE 转发同时解析 usage，流结束后扣预算（Anthropic/Gemini 等按事件里的 usage 字段识别）

### `/v1/models`

```bash
curl -H "Authorization: Bearer sk-team-a" http://kong:8000/v1/models
```

启用虚拟 Key 时仅返回该 Key 允许的别名；条目含 `ai-router.provider` / `upstream_model` / `deployments` 数。

## 配置参考

### 顶层

| 参数 | 默认 | 说明 |
|------|------|------|
| `model_list` | （必填） | 模型别名与部署列表 |
| `routing_strategy` | `simple-shuffle` | 见上文路由策略 |
| `semantic` | — | 语义路由 embeddings 配置 |
| `num_retries` | `2` | 非流式：同部署失败后的重试次数（0–10） |
| `stream_num_retries` | `1` | 流式首包前：同部署重试次数（更严） |
| `max_attempts` | `8` | 单次请求总尝试硬上限（含 fallback） |
| `max_retry_backoff` | `1000` | 重试指数退避上限（ms）；连接失败跳过退避 |
| `connect_timeout` | `2000` | 上游 TCP/TLS 连接超时（ms）；可被部署级覆盖 |
| `send_timeout` | `10000` | 上游发送超时（ms）；可被部署级覆盖 |
| `timeout` | `60000` | 上游读超时（ms）；流式为单次 socket read；可被部署级覆盖 |
| `keepalive_timeout` | `60000` | 上游 HTTP 连接池空闲超时（ms） |
| `keepalive_pool_size` | `128` | 上游 HTTP 连接池大小（每 worker / host） |
| `state_cache_ttl` | `1` | Redis 模式下 cooldown 本地 shdict 缓存（秒）；0=关 |
| `ssl_verify` | `true` | 上游 HTTPS 证书校验；可被部署级 `litellm_params.ssl_verify` 覆盖 |
| `max_inflight` | `0` | 全局 in-flight 上限（含流式）；`0`=不限制；超限 429 |
| `retry_after` | `200` | 重试退避基数（ms） |
| `allowed_fails` | `3` | 连续失败达此次数后进入冷却 |
| `cooldown_time` | `5` | 冷却时长（秒） |
| `enable_pre_call_checks` | `true` | 选路时跳过冷却中的部署 |
| `fallbacks` | `[]` | 通用 fallback 规则 |
| `default_fallbacks` | `[]` | 无专用规则时的默认通用链 |
| `context_window_fallbacks` | `[]` | 上下文超限专用链 |
| `content_policy_fallbacks` | `[]` | 内容策略专用链 |
| `path_patterns` | chat/completions/embeddings 常见路径 | 插件接管的路径后缀 |
| `enable_models_endpoint` | `true` | 是否响应 GET `/v1/models` |
| `drop_params` | `true` | 转发前丢弃不兼容参数 |
| `return_model_in_response` | `true` | 响应 `model` 字段使用客户端别名 |
| `response_headers` | `true` | 是否写入诊断响应头 |
| `state_backend` | `redis` | `redis`（跨节点，默认）或 `local`（共享内存） |
| `shared_dict` | `ai_router` | `lua_shared_dict` 名称 |
| `redis` | — | Redis 连接（默认后端为 redis，**`host` 必填**；仅 `state_backend=local` 时可省略） |
| `enable_virtual_keys` | `false` | 启用虚拟 Key 鉴权与预算 |
| `master_key` | — | 主 Key |
| `virtual_keys` | `[]` | 虚拟 Key 列表 |

### `model_list[]`

| 字段 | 说明 |
|------|------|
| `model_name` | 对外别名（客户端 `model`） |
| `description` | 语义路由用的能力描述 |
| `catch_all` | 语义未命中阈值时的兜底部署 |
| `litellm_params` | Provider 参数（见下） |
| `model_info` | `/v1/models` 附加信息（如 `owned_by`、`created`） |

### `litellm_params`

| 字段 | 说明 |
|------|------|
| `model` | `provider/model` 字符串 |
| `api_base` / `api_key` | 上游地址与密钥 |
| `api_version` | Azure api-version（默认 `2024-02-15-preview`） |
| `aws_region_name` | Bedrock region（默认 `us-east-1`） |
| `organization` | OpenAI organization header |
| `weight` | simple-shuffle 权重（默认 1） |
| `order` | 部署优先级，越小越高（默认 1） |
| `rpm` / `tpm` | 限流感知；也可作 shuffle 权重推导 |
| `input_cost_per_token` / `output_cost_per_token` | 预算扣费与 cost 路由 |
| `timeout` / `connect_timeout` / `send_timeout` | 部署级超时覆盖（ms） |
| `ssl_verify` | 部署级 TLS 校验覆盖 |
| `max_tokens` / `temperature` | 部署级覆盖 |
| `extra_headers` | 额外上游请求头 |

### `semantic`

| 字段 | 默认 | 说明 |
|------|------|------|
| `api_base` | OpenAI embeddings | Embeddings API |
| `api_key` | — | 必填当 `routing_strategy=semantic` |
| `model` | `text-embedding-3-small` | Embedding 模型 |
| `threshold` | `0.3` | 最小余弦相似度 |
| `selector_model` | `auto` | 触发跨别名语义选择的 model 名 |
| `catch_all_model` | — | 跨别名无命中时的回退别名 |
| `max_prompt_chars` | `4000` | 参与 embedding 的 prompt 上限 |
| `cache_ttl` | `86400` | 描述/文本 embedding 缓存 TTL（秒） |

### `virtual_keys[]`

| 字段 | 说明 |
|------|------|
| `key` | Bearer / x-api-key 值 |
| `name` | 显示名 |
| `models` | 允许别名；空=全部；支持 `*` 尾缀 |
| `max_budget` | 最大花费；空/0=不限 |
| `token_cost` | 部署无单价时按 token 总数 × 此值扣费 |
| `blocked` | 禁用该 Key |

## 工具调用

客户端按 OpenAI 格式传 `tools` / `tool_choice` / `messages[].tool_calls` / `role=tool`。  
插件在 Anthropic、Bedrock、Gemini 之间自动转换；响应统一为 OpenAI `tool_calls`。

OpenAI / Azure / 兼容网关原样透传。

## 诊断头

`response_headers=true` 时可能返回：

| Header | 含义 |
|--------|------|
| `x-ai-router-model` | 实际使用的别名 |
| `x-ai-router-upstream-model` | 上游真实模型 ID |
| `x-ai-router-provider` | 厂商 |
| `x-ai-router-deployment` | 部署标识 |
| `x-ai-router-attempts` | 尝试次数 |
| `x-ai-router-strategy` | 本次生效策略 |
| `x-ai-router-semantic-score` | 语义相似度 |
| `x-ai-router-semantic-model` | 客户端原始 selector（如 `auto`） |
| `x-ai-router-fallback-reason` | `request` / `context_window` / `content_policy` |
| `x-ai-router-key-name` | 虚拟 Key 名 |
| `x-ai-router-spend` / `x-ai-router-max-budget` | 预算 |
| `x-ai-router-models` | `/v1/models` 返回条数 |

## 行为说明

1. 匹配路径后由插件出站，**不再转发** Kong Service。
2. `stream=true`：首包成功前可 fallback；开始写流后不再切换；SSE 收齐后按 usage 扣预算。
3. Redis 用于 cooldown / busy / latency / rpm·tpm / spend / embedding 缓存跨节点共享。
4. 错误分类：按上游响应体识别 `context_window` / `content_policy`（OpenAI / Azure / Anthropic / Gemini / Bedrock 常见文案），再选对应专用链。
5. 请求体 `fallbacks` / `models` / `disable_fallbacks` 控制本次模型链。
6. 重试顺序：同部署重试 → 同 order 其它部署 → 更高 order → fallback 链中的下一别名。
7. 上游 HTTP 使用拆分超时：`connect_timeout` / `send_timeout` / `timeout`(read)；不可达上游会在连接阶段快速失败。
8. Provider / Redis 连接池：`keepalive_timeout` + `keepalive_pool_size`；选路在 Redis 模式下一次 MGET 预取 cooldown/busy/latency/usage，并用短 TTL 本地缓存 cooldown。
9. 重试受 `num_retries` / `stream_num_retries` / `max_attempts` / `max_retry_backoff` 约束；连接错误不再额外 sleep。
10. `ssl_verify` 默认 `true`；`max_inflight>0` 时全局并发闸门保护 worker 连接槽。
11. **配额原子化（按优先级）**  
    - 虚拟 Key 预算：入口 `check_budget` 与扣费 `charge` 共用 `spend_lock` / Redis EVAL（`spend >= max_budget` 拒入）；扣费仍保证 spend 不超过 `max_budget`。近限额并发仍可能先打上游、后扣费失败（只记日志）。  
    - `usage-based-routing`：选路时锁定读用量，并 **预扣 rpm**；成功只补 tpm/延迟，失败回滚预扣。仅配 tpm、未配 rpm 时仍只能做门禁检查、无法预扣 token。  
    - `max_inflight`：Redis 单次 Lua `INCR`+封顶；local 下 shdict 锁后 check-and-incr。

## 测试

```bash
cd ai-router-1.0.0 && lua spec/unit_spec.lua
```

覆盖：超时归一化、错误分类、预算决策、虚拟 Key 模型匹配、Fallback 索引、SSE usage、Provider 前缀解析、usage 锁/预扣、budget_admit、inflight 占槽。
