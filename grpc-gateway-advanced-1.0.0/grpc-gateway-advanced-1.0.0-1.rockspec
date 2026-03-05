package = "grpc-gateway-advanced"
version = "1.0.0-1"


supported_platforms = {"linux", "macosx"}
source = {
  url = "git://github.com/kelvins-io/kong-plugins/grpc-gateway-advanced",
  tag = "1.0.0",
}

description = {
  summary = "grpc-gateway-advanced is a grpc-gateway advanced plugin in Kong",
  homepage = "https://github.com/kelvins-io/grpc-gateway-advanced",
  license = "AGPL-3"
}

dependencies = {
  "lua >= 5.1",
  "lua-resty-http >= 0.16",
  "luafilesystem >= 1.6"
}

local pluginName = "grpc-gateway-advanced"
build = {
  type = "builtin",
  modules = {
    ["kong.plugins."..pluginName..".handler"] = "kong/plugins/"..pluginName.."/handler.lua",
    ["kong.plugins."..pluginName..".schema"] = "kong/plugins/"..pluginName.."/schema.lua",
    ["kong.plugins."..pluginName..".proto_loader"] = "kong/plugins/"..pluginName.."/proto_loader.lua",
    ["kong.plugins."..pluginName..".api"] = "kong/plugins/"..pluginName.."/api.lua",
  }
}