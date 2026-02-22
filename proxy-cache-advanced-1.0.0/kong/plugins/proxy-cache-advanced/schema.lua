local strategies = require "kong.plugins.proxy-cache-advanced.strategies"
local typedefs = require "kong.db.schema.typedefs"


local ngx = ngx


local function check_shdict(name)
  if not ngx.shared[name] then
    return false, "missing shared dict '" .. name .. "'"
  end

  return true
end


return {
  name = "proxy-cache-advanced",
  fields = {
    { protocols = typedefs.protocols },
    { config = {
        type = "record",
        fields = {
          { response_code = { description = "Upstream response status code considered cacheable.", type = "array",
            default = { 200, 301, 404 },
            elements = { type = "integer", between = {100, 900} },
            len_min = 1,
            required = true,
          }},
          { request_method = { description = "Downstream request methods considered cacheable.", type = "array",
            default = { "GET", "HEAD" },
            elements = {
              type = "string",
              one_of = { "HEAD", "GET", "POST", "PATCH", "PUT" },
            },
            required = true
          }},
          { content_type = { description = "Upstream response content types considered cacheable. The plugin performs an **exact match** against each specified value.", type = "array",
            default = { "text/plain","application/json" },
            elements = { type = "string" },
            required = true,
          }},
          { cache_ttl = { description = "TTL, in seconds, of cache entities.", type = "integer",
            default = 300,
            gt = 0,
          }},
          { strategy = { description = "The backing data store in which to hold cache entities.", type = "string",
            one_of = strategies.STRATEGY_TYPES,
            required = true,
          }},
          { cache_control = { description = "When enabled, respect the Cache-Control behaviors defined in RFC7234.", type = "boolean",
            default = false,
            required = true,
          }},
          { ignore_uri_case = {
            type = "boolean",
            default = false,
            required = false,
          }},
          { storage_ttl = { description = "Number of seconds to keep resources in the storage backend. This value is independent of `cache_ttl` or resource TTLs defined by Cache-Control behaviors.", type = "integer",
          }},
          { max_body_size = { description = "Maximum response body size (in bytes) to cache. Responses larger than this value will not be cached. Set to 0 to disable size limit.", type = "integer",
            default = 0,
            required = false,
          }},
          { memory = {
            type = "record",
            fields = {
              { dictionary_name = { description = "The name of the shared dictionary in which to hold cache entities when the memory strategy is selected. Note that this dictionary currently must be defined manually in the Kong Nginx template.", type = "string",
                required = true,
                default = "kong_db_cache",
              }},
            },
          }},
          { redis = {
            type = "record",
            fields = {
              { host = typedefs.host({ description = "When using the `redis` strategy, this property specifies the host to connect to.", default = "127.0.0.1" }) },
              { port = typedefs.port({ description = "When using the `redis` strategy, this property specifies the port on which to connect to the Redis server.", default = 6379 }) },
              { password = { description = "When using the `redis` strategy, this property specifies the password to connect to the Redis server.", type = "string", len_min = 0, referenceable = true } },
              { username = { description = "When using the `redis` strategy, this property specifies the username to connect to the Redis server when ACL authentication is desired.", type = "string", referenceable = true } },
              { ssl = { description = "When using the `redis` strategy, this property specifies if SSL is used to connect to the Redis server.", type = "boolean", required = true, default = false } },
              { ssl_verify = { description = "When using the `redis` strategy with `ssl` set to `true`, this property specifies it server SSL certificate is validated. Note that you need to configure the lua_ssl_trusted_certificate to specify the CA (or server) certificate used by your Redis server. You may also need to configure lua_ssl_verify_depth accordingly.", type = "boolean", required = true, default = false } },
              { server_name = typedefs.sni({ description = "When using the `redis` strategy with `ssl` set to `true`, this property specifies the server name for the SNI (Server Name Indication) extension used in the TLS handshake." }) },
              { timeout = { description = "When using the `redis` strategy, this property specifies the timeout in milliseconds of any command submitted to the Redis server.", type = "number", default = 2000 } },
              { database = { description = "When using the `redis` strategy, this property specifies the Redis database to use.", type = "integer", default = 0 } },
              { key_prefix = { description = "When using the `redis` strategy, this property specifies the key prefix for all cache keys stored in Redis.", type = "string", default = "proxy-cache-advanced:" } },
            },
          }},
          { disk = {
            type = "record",
            fields = {
              { path = { description = "When using the `disk` strategy, this property specifies the directory path where cache files are stored. The directory will be created if it does not exist.", type = "string", required = true, default = "/usr/local/kong/tmp/kong-proxy-cache" } },
            },
          }},
          { vary_query_params = { description = "Relevant query parameters considered for the cache key. If undefined, all params are taken into consideration.", type = "array",
            elements = { type = "string" },
          }},
          { vary_headers = { description = "Relevant headers considered for the cache key. If undefined, none of the headers are taken into consideration.", type = "array",
            elements = { type = "string" },
          }},
        },
      }
    },
  },

  entity_checks = {
    { custom_entity_check = {
      field_sources = { "config" },
      fn = function(entity)
        local config = entity.config

        if config.strategy == "memory" then
          local ok, err = check_shdict(config.memory.dictionary_name)
          if not ok then
            return nil, err
          end

        elseif config.strategy == "redis" then
          if not config.redis then
            return nil, "redis configuration is required when using redis strategy"
          end

          if not config.redis.host then
            return nil, "redis.host is required when using redis strategy"
          end

          if not config.redis.port then
            return nil, "redis.port is required when using redis strategy"
          end

        elseif config.strategy == "disk" then
          if not config.disk then
            return nil, "disk configuration is required when using disk strategy"
          end

          if not config.disk.path or config.disk.path == "" then
            return nil, "disk.path is required when using disk strategy"
          end
        end

        return true
      end
    }},
  },
}
