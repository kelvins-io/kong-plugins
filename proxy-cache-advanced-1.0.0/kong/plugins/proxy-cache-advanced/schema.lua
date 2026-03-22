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
            required = true,
          }},
          { storage_ttl = { description = "Number of seconds to keep resources in the storage backend. This value is independent of `cache_ttl` or resource TTLs defined by Cache-Control behaviors.", type = "integer",
          }},
          { max_body_size = { description = "Maximum response body size (in bytes) to cache. Responses larger than this value will not be cached. Default is 5 MiB (5242880). Set to 0 to disable size limit.", type = "integer",
            default = 5242880,
            required = false,
          }},
          { lock_redis = {
            type = "record",
            description = "Optional separate Redis used only for cache stampede lock. When enabled, only one request per key hits upstream; others retry fetch until cache is populated or timeout.",
            fields = {
              { host = typedefs.host({ description = "Redis host for lock.", default = "127.0.0.1" }) },
              { port = typedefs.port({ description = "Redis port for lock.", default = 6379 }) },
              { password = { description = "Redis password for lock.", type = "string", len_min = 0, referenceable = true } },
              { username = { description = "Redis username for lock (ACL).", type = "string", referenceable = true } },
              { ssl = { description = "Use SSL for lock Redis.", type = "boolean", default = false, required = true } },
              { ssl_verify = { description = "Verify SSL certificate for lock Redis.", type = "boolean", default = false, required = true } },
              { server_name = typedefs.sni({ description = "SNI for lock Redis TLS." }) },
              { timeout = { description = "Timeout in seconds for lock Redis commands.", type = "number", default = 5 } },
              { database = { description = "Redis database for lock.", type = "integer", default = 0 } },
              { key_prefix = { description = "Key prefix for lock keys in Redis.", type = "string", default = "proxy-cache-advanced:lock:" } },
              { enable_cache_lock = { description = "Enable distributed lock to prevent cache penetration. Value: \"true\" or \"false\" (string).", type = "string", one_of = { "true", "false" }, default = "false", required = true } },
              { cache_lock_ttl = { description = "Lock TTL in seconds; prevents deadlock if holder crashes.", type = "integer", default = 10, gt = 0 } },
              { cache_lock_retry_count = { description = "Number of fetch retries when waiting for cache.", type = "integer", default = 50, gt = 0 } },
              { cache_lock_retry_delay = { description = "Delay in seconds between fetch retries.", type = "number", default = 0.1, gt = 0 } },
            },
          }},
          { memory = {
            type = "record",
            fields = {
              { dictionary_name = { description = "The name of the shared dictionary in which to hold cache entities when the memory strategy is selected. Note that this dictionary currently must be defined manually in the Kong Nginx template.", type = "string",
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
              { ssl = { description = "When using the `redis` strategy, this property specifies if SSL is used to connect to the Redis server.", type = "boolean", default = false, required = true } },
              { ssl_verify = { description = "When using the `redis` strategy with `ssl` set to `true`, this property specifies it server SSL certificate is validated. Note that you need to configure the lua_ssl_trusted_certificate to specify the CA (or server) certificate used by your Redis server. You may also need to configure lua_ssl_verify_depth accordingly.", type = "boolean", default = false, required = true } },
              { server_name = typedefs.sni({ description = "When using the `redis` strategy with `ssl` set to `true`, this property specifies the server name for the SNI (Server Name Indication) extension used in the TLS handshake." }) },
              { timeout = { description = "When using the `redis` strategy, this property specifies the timeout in seconds of any command submitted to the Redis server.", type = "number", default = 60 } },
              { database = { description = "When using the `redis` strategy, this property specifies the Redis database to use.", type = "integer", default = 0 } },
              { key_prefix = { description = "When using the `redis` strategy, this property specifies the key prefix for all cache keys stored in Redis.", type = "string", default = "proxy-cache-advanced:" } },
            },
          }},
          { disk = {
            type = "record",
            fields = {
              { path = { description = "When using the `disk` strategy, this property specifies the directory path where cache files are stored. The directory will be created if it does not exist.", type = "string", default = "/usr/local/kong/tmp/kong-proxy-cache" } },
            },
          }},
          { tcos = {
            type = "record",
            description = "When using the `tcos` strategy, cache objects are stored in Tencent Cloud COS (Cloud Object Storage).",
            fields = {
              { secret_id = { description = "Tencent Cloud API SecretId (from CAM API Key).", type = "string", referenceable = true } },
              { secret_key = { description = "Tencent Cloud API SecretKey (from CAM API Key).", type = "string", referenceable = true } },
              { bucket = { description = "COS bucket name (e.g. mybucket-1234567890).", type = "string" } },
              { region = { description = "COS region (e.g. ap-guangzhou, ap-beijing).", type = "string", default = "ap-guangzhou" } },
              { key_prefix = { description = "Object key prefix for cache entries (e.g. proxy-cache-advanced/).", type = "string", default = "proxy-cache-advanced/" } },
              { timeout = { description = "Request timeout in seconds.", type = "integer", default = 60, gt = 0 } },
              { endpoint = { description = "Optional custom endpoint host (e.g. mybucket.cos.ap-guangzhou.myqcloud.com). Leave empty to use default.", type = "string" } },
              { scheme = { description = "HTTP scheme (https or http).", type = "string", default = "https", one_of = { "https", "http" } } },
              { ssl_verify = { description = "Set to false to skip TLS certificate verification (e.g. when encountering self-signed certificate in certificate chain).", type = "boolean", default = true, required = true } },
            },
          }},
          { aoss = {
            type = "record",
            description = "When using the `oss` strategy, cache objects are stored in Alibaba Cloud OSS (Object Storage Service).",
            fields = {
              { access_key_id = { description = "Alibaba Cloud AccessKey ID.", type = "string", referenceable = true } },
              { access_key_secret = { description = "Alibaba Cloud AccessKey Secret.", type = "string", referenceable = true } },
              { bucket = { description = "OSS bucket name.", type = "string" } },
              { endpoint = { description = "OSS endpoint host (e.g. mybucket.oss-cn-hangzhou.aliyuncs.com). Leave empty to use bucket.oss-cn-hangzhou.aliyuncs.com.", type = "string" } },
              { region = { description = "OSS region (e.g. oss-cn-hangzhou). Used to build endpoint when endpoint is not set.", type = "string", default = "oss-cn-hangzhou" } },
              { key_prefix = { description = "Object key prefix for cache entries (e.g. proxy-cache-advanced/).", type = "string", default = "proxy-cache-advanced/" } },
              { timeout = { description = "Request timeout in seconds.", type = "integer", default = 60, gt = 0 } },
              { scheme = { description = "HTTP scheme (https or http).", type = "string", default = "https", one_of = { "https", "http" } } },
              { ssl_verify = { description = "Set to false to skip TLS certificate verification.", type = "boolean", default = true, required = true } },
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

        elseif config.strategy == "tcos" then
          if not config.tcos then
            return nil, "tcos configuration is required when using tcos strategy"
          end
          if not config.tcos.secret_id or config.tcos.secret_id == "" then
            return nil, "tcos.secret_id is required when using tcos strategy"
          end
          if not config.tcos.secret_key or config.tcos.secret_key == "" then
            return nil, "tcos.secret_key is required when using tcos strategy"
          end
          if not config.tcos.bucket or config.tcos.bucket == "" then
            return nil, "tcos.bucket is required when using tcos strategy"
          end

        elseif config.strategy == "aoss" then
          if not config.aoss then
            return nil, "aoss configuration is required when using aoss strategy"
          end
          if not config.aoss.access_key_id or config.aoss.access_key_id == "" then
            return nil, "aoss.access_key_id is required when using aoss strategy"
          end
          if not config.aoss.access_key_secret or config.aoss.access_key_secret == "" then
            return nil, "aoss.access_key_secret is required when using aoss strategy"
          end
          if not config.aoss.bucket or config.aoss.bucket == "" then
            return nil, "aoss.bucket is required when using oss strategy"
          end
        end

        if config.lock_redis and (config.lock_redis.enable_cache_lock == true or config.lock_redis.enable_cache_lock == "true") then
          if not config.lock_redis.host or not config.lock_redis.port then
            return nil, "lock_redis.host and lock_redis.port are required when enable_cache_lock is true"
          end
        end

        return true
      end
    }},
  },
}
