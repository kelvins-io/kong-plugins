package = "proxy-cache-advanced"
version = "1.0.0-1"


supported_platforms = {"linux", "macosx"}
source = {
  url = "git://github.com/kelvins-io/kong-plugins/proxy-cache-advanced",
  tag = "1.0.0",
}

description = {
  summary = "proxy-cache-advanced is a proxy-cache advanced plugin in Kong",
  homepage = "https://github.com/kelvins-io/proxy-cache-advanced",
  license = "AGPL-3"
}

dependencies = {
  "lua >= 5.1"
}

local pluginName = "proxy-cache-advanced"
build = {
  type = "builtin",
  modules = {
    ["kong.plugins."..pluginName..".handler"] = "kong/plugins/"..pluginName.."/handler.lua",
    ["kong.plugins."..pluginName..".schema"] = "kong/plugins/"..pluginName.."/schema.lua",
  }
}