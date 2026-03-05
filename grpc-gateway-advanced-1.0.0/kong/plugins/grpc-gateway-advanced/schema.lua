local typedefs = require "kong.db.schema.typedefs"

return {
  name = "grpc-gateway-advanced",
  fields = {
    { protocols = typedefs.protocols },
    { config = {
      type = "record",
      fields = {
        {
          proto = {
            description = "Describes the gRPC types and methods. Can be a local file path or a remote URL (http/https, e.g. raw Git file URL). Remote URLs are fetched and cached locally.",
            type = "string",
            required = false,
            default = nil,
          },
        },
        {
          proto_cache_dir = {
            description = "When proto is a remote URL, cache directory for downloaded .proto files. Default: /usr/local/kong/tmp/proto_cache",
            type = "string",
            required = false,
            default = "/usr/local/kong/tmp/proto_cache",
          },
        },
        {
          proto_fetch_timeout = {
            description = "Timeout in seconds when fetching proto from remote URL. Default: 10.",
            type = "number",
            required = false,
            default = 10,
          },
        },
      },
    }, },
  },
}
