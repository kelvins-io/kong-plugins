local typedefs = require "kong.db.schema.typedefs"

return {
  name = "grpc-web",
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
            default = "/usr/local/kong/tmp/proto_cache",
          },
        },
        {
          proto_fetch_timeout = { description = "Timeout in seconds when fetching proto from remote URL. Default: 10.", type = "number",
            required = false,
            default = 10,
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
