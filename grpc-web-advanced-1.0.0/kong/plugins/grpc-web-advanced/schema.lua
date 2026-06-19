local typedefs = require "kong.db.schema.typedefs"

return {
  name = "grpc-web-advanced",
  fields = {
    { protocols = typedefs.protocols },
    { config = {
      type = "record",
      fields = {
        {
          proto = { description = "If present, describes the gRPC types and methods. Required to support payload transcoding. When absent, the web client must use application/grpw-web+proto content. Can be a local file path or a remote URL (http/https, e.g. raw Git file URL). Remote URLs are fetched and cached locally.", type = "string",
            required = false,
            default = nil,
          },
        },
        {
          proto_cache_dir = { description = "When proto is a remote URL, cache directory for downloaded .proto files. Default: /tmp/kong_grpc_web_proto_cache", type = "string",
            required = false,
            default = "/usr/local/kong/proto_cache",
          },
        },
        {
          proto_fetch_timeout = { description = "Timeout in seconds when fetching proto from remote URL. Default: 10.", type = "number",
            required = false,
            default = 10,
          },
        },
        {
          proto_fetch_ssl_verify = { description = "When proto is an https:// URL, whether to verify the remote TLS certificate. Default: true.", type = "boolean",
            required = false,
            default = false,
          },
        },
        {
          lock_dict_name = { description = "Shared dict name for resty.lock when downloading remote proto files. Must be defined in the Kong Nginx template (e.g. kong_locks). When the dict is unavailable, proto is fetched without deduplication.", type = "string",
            required = false,
            default = "kong_locks",
          },
        },
        {
          lock_dict_key_prefix = { description = "Key prefix for lock entries in the shared dict when downloading remote proto files.", type = "string",
            required = false,
            default = "grpc-web-advanced:proto:",
          },
        },
        {
          pass_stripped_path = { description = "If set to `true` causes the plugin to pass the stripped request path to the upstream gRPC service.", type = "boolean",
            required = false,
          },
        },
        {
          allow_origin_header = { description = "The value of the `Access-Control-Allow-Origin` header in the response to the gRPC-Web client.", type = "string",
            required = false,
            default = "*",
          },
        },
      },
    }, },
  },
}
