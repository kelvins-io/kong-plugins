package = "response-ratelimiting-advanced"
version = "1.0.0-1"


supported_platforms = {"linux", "macosx"}
source = {
  url = "git://github.com/kelvins-io/kong-plugins/response-ratelimiting-advanced",
  tag = "1.0.0",
}

description = {
  summary = "response-ratelimiting-advanced is a response-ratelimiting-advanced plugin in Kong",
  homepage = "https://github.com/kelvins-io/response-ratelimiting-advanced",
  license = "AGPL-3"
}

dependencies = {
  "lua >= 5.1",
}

local pluginName = "response-ratelimiting-advanced"
build = {
  type = "builtin",
  modules = {
    ["kong.plugins."..pluginName..".handler"] = "kong/plugins/"..pluginName.."/handler.lua",
    ["kong.plugins."..pluginName..".schema"] = "kong/plugins/"..pluginName.."/schema.lua",
    ["kong.plugins."..pluginName..".access"] = "kong/plugins/"..pluginName.."/access.lua",
    ["kong.plugins."..pluginName..".header_filter"] = "kong/plugins/"..pluginName.."/header_filter.lua",
    ["kong.plugins."..pluginName..".body_filter"] = "kong/plugins/"..pluginName.."/body_filter.lua",
    ["kong.plugins."..pluginName..".llm_usage"] = "kong/plugins/"..pluginName.."/llm_usage.lua",
    ["kong.plugins."..pluginName..".log"] = "kong/plugins/"..pluginName.."/log.lua",
    ["kong.plugins."..pluginName..".policies"] = "kong/plugins/"..pluginName.."/policies/init.lua",
  }
}