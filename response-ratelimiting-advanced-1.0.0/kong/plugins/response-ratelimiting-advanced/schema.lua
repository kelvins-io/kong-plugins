local typedefs = require "kong.db.schema.typedefs"


-- Inline Redis schema so the plugin loads on Kong 3.4 (no kong.tools.redis.schema).
local redis_schema = {
  type = "record",
  description = "Redis configuration",
  fields = {
    { host = typedefs.host },
    { port = typedefs.port { default = 6379 } },
    { timeout = {
        type = "integer",
        default = 2000,
        description = "An optional timeout in milliseconds when connecting to Redis.",
      }
    },
    { username = {
        type = "string",
        referenceable = true,
        description = "Username to use for Redis ACL authentication.",
      }
    },
    { password = {
        type = "string",
        len_min = 0,
        referenceable = true,
        description = "Password to use for Redis authentication.",
      }
    },
    { database = {
        type = "integer",
        default = 0,
        description = "Database to use for Redis connections.",
      }
    },
    { ssl = {
        type = "boolean",
        required = true,
        default = false,
        description = "If set to true, uses SSL to connect to Redis.",
      }
    },
    { ssl_verify = {
        type = "boolean",
        required = true,
        default = false,
        description = "If set to true, verifies the Redis server SSL certificate.",
      }
    },
    { server_name = typedefs.sni },
  },
}

local ORDERED_PERIODS = { "second", "minute", "hour", "day", "month", "year" }


local function validate_periods_order(limit)
  for i, lower_period in ipairs(ORDERED_PERIODS) do
    local v1 = limit[lower_period]
    if type(v1) == "number" then
      for j = i + 1, #ORDERED_PERIODS do
        local upper_period = ORDERED_PERIODS[j]
        local v2 = limit[upper_period]
        if type(v2) == "number" and v2 < v1 then
          return nil, string.format("the limit for %s(%.1f) cannot be lower than the limit for %s(%.1f)",
            upper_period, v2, lower_period, v1)
        end
      end
    end
  end

  return true
end


local policy = {
  description =
  "The rate-limiting policies to use for retrieving and incrementing the limits.",
  type = "string",
  default = "local",
  one_of = {
    "local",
    "redis",
  },
}

return {
  name = "response-ratelimiting-advanced",
  fields = {
    { protocols = typedefs.protocols_http },
    {
      config = {
        type = "record",
        fields = {
          {
            header_name = {
              description = "The name of the response header used to increment the counters.",
              type = "string",
              default = "x-kong-limit"
            },
          },
          {
            llm_usage = {
              description =
              "When enabled, increment counters from the `usage` object in the upstream JSON response body (e.g. `prompt_tokens`, `completion_tokens`, `total_tokens`) instead of the `header_name` response header. SSE (`text/event-stream`) is streamed through to the client; `usage` is read from the last non-DONE chunk after the stream ends. Only keys that also exist in `limits` are counted.",
              type = "boolean",
              required = true,
              default = false,
            },
          },
          {
            limit_by = {
              description =
              "The entity that will be used when aggregating the limits: `consumer`, `credential`, `ip`, `service`, `header`, `path`, `llm_model`. If the identifier cannot be determined, the system will always fallback to `ip`. When `limit_by` is `llm_model`, the identifier is the `model` field in the JSON request body.",
              type = "string",
              default = "consumer",
              one_of = { "consumer", "credential", "ip", "service", "header", "path", "llm_model" },
            },
          },
          {
            header = typedefs.header_name {
              description =
              "The name of the request header used to identify the client when `limit_by` is set to `header`.",
            },
          },
          {
            path = typedefs.path {
              description =
              "The request path used to identify the client when `limit_by` is set to `path`. Must start with a forward slash (/) and must not contain empty segments.",
            },
          },
          { policy = policy },
          {
            fault_tolerant = {
              description =
              "A boolean value that determines if the requests should be proxied even if Kong has troubles connecting a third-party datastore. If `true`, requests will be proxied anyway, effectively disabling the rate-limiting function until the datastore is working again. If `false`, then the clients will see `500` errors.",
              type = "boolean",
              required = true,
              default = true
            },
          },
          { redis = redis_schema },
          {
            block_on_first_violation = {
              description =
              "A boolean value that determines if the requests should be blocked as soon as one limit is being exceeded. This will block requests that are supposed to consume other limits too.",
              type = "boolean",
              required = true,
              default = false
            },
          },
          {
            hide_client_headers = {
              description = "Optionally hide informative response headers.",
              type = "boolean",
              required = true,
              default = false
            },
          },
          {
            limits = {
              description = "A map that defines rate limits for the plugin.",
              type = "map",
              required = true,
              len_min = 1,
              keys = { type = "string" },
              values = {
                type = "record",
                required = true,
                fields = {
                  { second = { type = "number", gt = 0 }, },
                  { minute = { type = "number", gt = 0 }, },
                  { hour = { type = "number", gt = 0 }, },
                  { day = { type = "number", gt = 0 }, },
                  { month = { type = "number", gt = 0 }, },
                  { year = { type = "number", gt = 0 }, },
                },
                custom_validator = validate_periods_order,
                entity_checks = {
                  { at_least_one_of = ORDERED_PERIODS },
                },
              },
            },
          },
        },
        shorthand_fields = {
          -- Aliases for the nested redis.* fields (Kong 3.4 has no `deprecation` schema attr).
          { redis_host = {
            type = "string",
            func = function(value)
              return { redis = { host = value } }
            end
          } },
          { redis_port = {
            type = "integer",
            func = function(value)
              return { redis = { port = value } }
            end
          } },
          { redis_password = {
            type = "string",
            len_min = 0,
            func = function(value)
              return { redis = { password = value } }
            end
          } },
          { redis_username = {
            type = "string",
            func = function(value)
              return { redis = { username = value } }
            end
          } },
          { redis_ssl = {
            type = "boolean",
            func = function(value)
              return { redis = { ssl = value } }
            end
          } },
          { redis_ssl_verify = {
            type = "boolean",
            func = function(value)
              return { redis = { ssl_verify = value } }
            end
          } },
          { redis_server_name = {
            type = "string",
            func = function(value)
              return { redis = { server_name = value } }
            end
          } },
          { redis_timeout = {
            type = "integer",
            func = function(value)
              return { redis = { timeout = value } }
            end
          } },
          { redis_database = {
            type = "integer",
            func = function(value)
              return { redis = { database = value } }
            end
          } },
        },
      },
    },
  },
  entity_checks = {
    { conditional = {
      if_field = "config.policy", if_match = { eq = "redis" },
      then_field = "config.redis.host", then_match = { required = true },
    } },
    { conditional = {
      if_field = "config.policy", if_match = { eq = "redis" },
      then_field = "config.redis.port", then_match = { required = true },
    } },
    { conditional = {
      if_field = "config.policy", if_match = { eq = "redis" },
      then_field = "config.redis.timeout", then_match = { required = true },
    } },
    { conditional = {
      if_field = "config.limit_by", if_match = { eq = "header" },
      then_field = "config.header", then_match = { required = true },
    } },
    { conditional = {
      if_field = "config.limit_by", if_match = { eq = "path" },
      then_field = "config.path", then_match = { required = true },
    } },
  },
}
