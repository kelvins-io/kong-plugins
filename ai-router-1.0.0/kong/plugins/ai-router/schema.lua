local typedefs = require "kong.db.schema.typedefs"


local redis_schema = {
  type = "record",
  description = "Redis configuration for cross-node state / budget.",
  fields = {
    { host = typedefs.host },
    { port = typedefs.port { default = 6379 } },
    { timeout = {
        type = "integer",
        default = 2000,
        description = "Redis connect/read timeout (ms).",
    }},
    { username = {
        type = "string",
        referenceable = true,
        description = "Redis ACL username.",
    }},
    { password = {
        type = "string",
        len_min = 0,
        referenceable = true,
        description = "Redis password.",
    }},
    { database = {
        type = "integer",
        default = 0,
        description = "Redis database index.",
    }},
    { ssl = {
        type = "boolean",
        required = true,
        default = false,
    }},
    { ssl_verify = {
        type = "boolean",
        required = true,
        default = false,
    }},
    { server_name = typedefs.sni },
    { prefix = {
        type = "string",
        default = "ai_router",
        description = "Key prefix for Redis keys.",
    }},
    { keepalive_timeout = {
        type = "integer",
        default = 60000,
        gt = 0,
        description = "Redis idle keepalive timeout (ms).",
    }},
    { keepalive_pool_size = {
        type = "integer",
        default = 128,
        gt = 0,
        description = "Redis connection pool size per Kong worker.",
    }},
  },
}


local litellm_params = {
  type = "record",
  required = true,
  fields = {
    { model = {
        description = "Provider model：`openai/` `azure/` `anthropic/` `bedrock/` `gemini/` `groq/` `mistral/` `deepseek/` 等。",
        type = "string",
        required = true,
    }},
    { api_base = {
        description = "Provider API base。",
        type = "string",
    }},
    { api_key = {
        description = "Provider API key / Bedrock bearer token。",
        type = "string",
        referenceable = true,
        len_min = 0,
    }},
    { api_version = {
        description = "Azure OpenAI api-version。",
        type = "string",
        default = "2024-02-15-preview",
    }},
    { aws_region_name = {
        description = "Bedrock region，默认 us-east-1。",
        type = "string",
    }},
    { organization = {
        description = "OpenAI organization header。",
        type = "string",
    }},
    { weight = {
        description = "simple-shuffle 权重。",
        type = "number",
        gt = 0,
        default = 1,
    }},
    { order = {
        description = "部署优先级，越小越高。",
        type = "integer",
        default = 1,
        gt = 0,
    }},
    { rpm = { type = "number", gt = 0 }},
    { tpm = { type = "number", gt = 0 }},
    { input_cost_per_token = {
        description = "输入 token 单价（预算扣费 / cost 路由）。",
        type = "number",
        gt = 0,
    }},
    { output_cost_per_token = {
        description = "输出 token 单价（预算扣费 / cost 路由）。",
        type = "number",
        gt = 0,
    }},
    { timeout = {
        description = "部署级 read 超时（ms），覆盖插件 `timeout`。",
        type = "integer",
        gt = 0,
    }},
    { connect_timeout = {
        description = "部署级 connect 超时（ms），覆盖插件 `connect_timeout`。",
        type = "integer",
        gt = 0,
    }},
    { send_timeout = {
        description = "部署级 send 超时（ms），覆盖插件 `send_timeout`。",
        type = "integer",
        gt = 0,
    }},
    { ssl_verify = {
        description = "部署级上游 TLS 校验；覆盖插件 `ssl_verify`。",
        type = "boolean",
    }},
    { max_tokens = { type = "integer", gt = 0 }},
    { temperature = { type = "number" }},
    { extra_headers = {
        type = "map",
        keys = { type = "string" },
        values = { type = "string" },
    }},
  },
}


local model_entry = {
  type = "record",
  required = true,
  fields = {
    { model_name = {
        description = "对外模型别名。",
        type = "string",
        required = true,
    }},
    { description = {
        description = "语义路由用的模型/部署能力描述；与 prompt embedding 做相似度匹配。",
        type = "string",
    }},
    { catch_all = {
        description = "语义路由未命中阈值时的兜底部署。",
        type = "boolean",
        default = false,
        required = true,
    }},
    { litellm_params = litellm_params },
    { model_info = {
        type = "map",
        keys = { type = "string" },
        values = { type = "string" },
    }},
  },
}


local semantic_schema = {
  type = "record",
  fields = {
    { api_base = {
        description = "Embeddings API base（OpenAI 兼容），默认 https://api.openai.com/v1。",
        type = "string",
        default = "https://api.openai.com/v1",
    }},
    { api_key = {
        description = "Embeddings API key。",
        type = "string",
        referenceable = true,
        len_min = 0,
    }},
    { model = {
        description = "Embedding 模型名。",
        type = "string",
        default = "text-embedding-3-small",
    }},
    { timeout = {
        description = "Embeddings 请求超时（毫秒）。",
        type = "integer",
        default = 5000,
        gt = 0,
    }},
    { threshold = {
        description = "最小余弦相似度；低于此值的描述不参与匹配（除非 catch_all）。",
        type = "number",
        default = 0.3,
        between = { -1, 1 },
    }},
    { selector_model = {
        description = "客户端使用该 model 名时触发跨模型语义选择（默认 auto）。",
        type = "string",
        default = "auto",
    }},
    { catch_all_model = {
        description = "跨模型语义无命中时回退的 model_name。",
        type = "string",
    }},
    { max_prompt_chars = {
        description = "参与 embedding 的 prompt 最大字符数。",
        type = "integer",
        default = 4000,
        gt = 0,
    }},
    { cache_ttl = {
        description = "描述/文本 embedding 缓存 TTL（秒）。",
        type = "integer",
        default = 86400,
        gt = 0,
    }},
    { extra_headers = {
        type = "map",
        keys = { type = "string" },
        values = { type = "string" },
    }},
  },
}


local fallback_rule = {
  type = "record",
  required = true,
  fields = {
    { model = { type = "string", required = true }},
    { fallbacks = {
        type = "array",
        required = true,
        elements = { type = "string" },
        len_min = 1,
    }},
  },
}


local virtual_key = {
  type = "record",
  required = true,
  fields = {
    { key = {
        description = "客户端 Bearer / x-api-key 值（虚拟 Key）。",
        type = "string",
        required = true,
        referenceable = true,
    }},
    { name = {
        description = "Key 显示名。",
        type = "string",
    }},
    { models = {
        description = "允许的 model_name；空=全部。支持尾缀 * 通配。",
        type = "array",
        elements = { type = "string" },
        default = {},
    }},
    { max_budget = {
        description = "最大花费（与 input/output_cost_per_token 同单位）；0/空=不限。",
        type = "number",
        gt = 0,
    }},
    { token_cost = {
        description = "部署未配置单价时，按 (prompt+completion)*token_cost 扣费。",
        type = "number",
        gt = 0,
    }},
    { blocked = {
        description = "禁用该 Key。",
        type = "boolean",
        default = false,
        required = true,
    }},
  },
}


return {
  name = "ai-router",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { model_list = {
              description = "对齐 LiteLLM model_list。",
              type = "array",
              required = true,
              len_min = 1,
              elements = model_entry,
          }},
          { routing_strategy = {
              type = "string",
              required = true,
              default = "simple-shuffle",
              one_of = {
                "simple-shuffle",
                "least-busy",
                "latency-based-routing",
                "cost-based-routing",
                "usage-based-routing",
                "semantic",
              },
          }},
          { semantic = semantic_schema },
          { num_retries = {
              description = "非流式：同一部署失败后的重试次数。",
              type = "integer",
              default = 2,
              between = { 0, 10 },
          }},
          { stream_num_retries = {
              description = "流式（首包前）：同一部署失败后的重试次数；默认比非流式更严。",
              type = "integer",
              default = 1,
              between = { 0, 10 },
          }},
          { max_attempts = {
              description = "单次请求总尝试次数硬上限（含 fallback 链），防止雪崩。",
              type = "integer",
              default = 8,
              between = { 1, 50 },
          }},
          { max_retry_backoff = {
              description = "重试指数退避上限（ms）；连接失败跳过退避。",
              type = "integer",
              default = 1000,
              gt = 0,
          }},
          { keepalive_timeout = {
              description = "上游 HTTP 连接池空闲超时（ms）。",
              type = "integer",
              default = 60000,
              gt = 0,
          }},
          { keepalive_pool_size = {
              description = "上游 HTTP 连接池大小（每 worker、每 host）。",
              type = "integer",
              default = 128,
              gt = 0,
          }},
          { state_cache_ttl = {
              description = "Redis 模式下 cooldown 的本地 shdict 缓存 TTL（秒）；0=禁用。降低选路 Redis 往返。",
              type = "integer",
              default = 1,
              between = { 0, 60 },
          }},
          { ssl_verify = {
              description = "校验上游 Provider HTTPS 证书；生产建议 true。可被部署级覆盖。",
              type = "boolean",
              default = true,
              required = true,
          }},
          { max_inflight = {
              description = "全局 in-flight 请求上限（含流式）；0=不限制。超限返回 429。",
              type = "integer",
              default = 0,
              between = { 0, 1000000 },
          }},
          { connect_timeout = {
              description = "上游 TCP/TLS 连接超时（ms）。连接失败快速失败，避免占满 worker 槽位。",
              type = "integer",
              default = 2000,
              gt = 0,
          }},
          { send_timeout = {
              description = "上游请求发送超时（ms）。",
              type = "integer",
              default = 10000,
              gt = 0,
          }},
          { timeout = {
              description = "上游读超时（ms）；流式场景为单次 socket read 超时。可被部署级 `litellm_params.timeout` 覆盖。",
              type = "integer",
              default = 60000,
              gt = 0,
          }},
          { retry_after = {
              type = "integer",
              default = 200,
              gt = 0,
          }},
          { allowed_fails = {
              type = "integer",
              default = 3,
              gt = 0,
          }},
          { cooldown_time = {
              type = "integer",
              default = 5,
              gt = 0,
          }},
          { enable_pre_call_checks = {
              type = "boolean",
              default = true,
              required = true,
          }},
          { fallbacks = {
              description = "通用 Fallback：限流 / 超时 / 5xx 等。",
              type = "array",
              elements = fallback_rule,
              default = {},
          }},
          { default_fallbacks = {
              description = "未配置专用 fallbacks 规则时的默认通用 Fallback 列表。",
              type = "array",
              elements = { type = "string" },
              default = {},
          }},
          { context_window_fallbacks = {
              description = "上下文超限（ContextWindowExceeded）时换更大窗口模型；匹配到专用链后不再走通用 fallbacks。",
              type = "array",
              elements = fallback_rule,
              default = {},
          }},
          { content_policy_fallbacks = {
              description = "内容审核拦截（ContentPolicyViolation）时换模型；匹配到专用链后不再走通用 fallbacks。",
              type = "array",
              elements = fallback_rule,
              default = {},
          }},
          { path_patterns = {
              type = "array",
              elements = { type = "string" },
              default = {
                "/chat/completions",
                "/completions",
                "/embeddings",
                "/v1/chat/completions",
                "/v1/completions",
                "/v1/embeddings",
              },
          }},
          { enable_models_endpoint = {
              description = "是否响应 GET /v1/models（及 /models）。",
              type = "boolean",
              default = true,
              required = true,
          }},
          { drop_params = {
              type = "boolean",
              default = true,
              required = true,
          }},
          { return_model_in_response = {
              type = "boolean",
              default = true,
              required = true,
          }},
          { response_headers = {
              type = "boolean",
              default = true,
              required = true,
          }},
          { state_backend = {
              description = "状态后端：redis（跨节点，默认）或 local（共享内存）。",
              type = "string",
              default = "redis",
              one_of = { "local", "redis" },
              required = true,
          }},
          { shared_dict = {
              type = "string",
              default = "ai_router",
          }},
          { redis = redis_schema },
          { enable_virtual_keys = {
              description = "启用虚拟 Key 鉴权与预算。",
              type = "boolean",
              default = false,
              required = true,
          }},
          { master_key = {
              description = "主 Key，可访问全部模型且不扣预算。",
              type = "string",
              referenceable = true,
              len_min = 0,
          }},
          { virtual_keys = {
              description = "虚拟 Key 列表（对齐 LiteLLM virtual keys 精简版）。",
              type = "array",
              elements = virtual_key,
              default = {},
          }},
        },
    }},
  },
  entity_checks = {
    { conditional = {
        if_field = "config.state_backend", if_match = { eq = "redis" },
        then_field = "config.redis.host", then_match = { required = true },
    }},
    { conditional = {
        if_field = "config.routing_strategy", if_match = { eq = "semantic" },
        then_field = "config.semantic.api_key", then_match = { required = true },
    }},
  },
}
