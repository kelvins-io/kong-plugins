package = "grpc-web-advanced"
version = "1.0.0-1"


supported_platforms = {"linux", "macosx"}
source = {
  url = "git://github.com/kelvins-io/kong-plugins/grpc-web-advanced",
  tag = "1.0.0",
}

description = {
  summary = "grpc-web-advanced is a grpc-web advanced plugin in Kong",
  homepage = "https://github.com/kelvins-io/grpc-web-advanced",
  license = "AGPL-3"
}

dependencies = {
  "lua >= 5.1",
  "lua-resty-http >= 0.16",
  "luafilesystem >= 1.6"
}

local pluginName = "grpc-web-advanced"
build = {
  type = "builtin",
  modules = {
    ["kong.plugins."..pluginName..".handler"] = "kong/plugins/"..pluginName.."/handler.lua",
    ["kong.plugins."..pluginName..".schema"] = "kong/plugins/"..pluginName.."/schema.lua",
    ["kong.plugins."..pluginName..".proto_loader"] = "kong/plugins/"..pluginName.."/proto_loader.lua",
    ["kong.plugins."..pluginName..".api"] = "kong/plugins/"..pluginName.."/api.lua",
  }
}