package = "response-gzip"
version = "1.0.0-1"

supported_platforms = {"linux", "macosx"}
source = {
  url = "git://github.com/kelvins-io/kong-plugins",
  tag = "response-gzip-1.0.0",
}

description = {
  summary = "Kong plugin: gzip-compress upstream response body before returning to client.",
  homepage = "https://github.com/kelvins-io/kong-plugins",
  license = "Apache-2.0",
}

dependencies = {
  "lua >= 5.1",
}

local plugin_name = "response-gzip"
build = {
  type = "builtin",
  modules = {
    ["kong.plugins." .. plugin_name .. ".handler"] = "kong/plugins/" .. plugin_name .. "/handler.lua",
    ["kong.plugins." .. plugin_name .. ".schema"] = "kong/plugins/" .. plugin_name .. "/schema.lua",
  },
}
