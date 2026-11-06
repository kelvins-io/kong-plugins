package = "ai-router"
version = "1.0.0-1"

supported_platforms = {"linux", "macosx"}
source = {
  url = "git://github.com/your-org/kong-plugins",
  tag = "ai-router-1.0.0",
}

description = {
  summary = "Kong plugin: LiteLLM-aligned AI model router with load balancing, retries and fallbacks.",
  homepage = "https://github.com/your-org/kong-plugins",
  license = "Apache-2.0",
}

dependencies = {
  "lua >= 5.1",
}

local plugin_name = "ai-router"
build = {
  type = "builtin",
  modules = {
    ["kong.plugins." .. plugin_name .. ".handler"] = "kong/plugins/" .. plugin_name .. "/handler.lua",
    ["kong.plugins." .. plugin_name .. ".schema"] = "kong/plugins/" .. plugin_name .. "/schema.lua",
    ["kong.plugins." .. plugin_name .. ".access"] = "kong/plugins/" .. plugin_name .. "/access.lua",
    ["kong.plugins." .. plugin_name .. ".router"] = "kong/plugins/" .. plugin_name .. "/router.lua",
    ["kong.plugins." .. plugin_name .. ".state"] = "kong/plugins/" .. plugin_name .. "/state.lua",
    ["kong.plugins." .. plugin_name .. ".http_client"] = "kong/plugins/" .. plugin_name .. "/http_client.lua",
    ["kong.plugins." .. plugin_name .. ".tools"] = "kong/plugins/" .. plugin_name .. "/tools.lua",
    ["kong.plugins." .. plugin_name .. ".models"] = "kong/plugins/" .. plugin_name .. "/models.lua",
    ["kong.plugins." .. plugin_name .. ".redis_store"] = "kong/plugins/" .. plugin_name .. "/redis_store.lua",
    ["kong.plugins." .. plugin_name .. ".virtual_keys"] = "kong/plugins/" .. plugin_name .. "/virtual_keys.lua",
    ["kong.plugins." .. plugin_name .. ".semantic"] = "kong/plugins/" .. plugin_name .. "/semantic.lua",
    ["kong.plugins." .. plugin_name .. ".errors"] = "kong/plugins/" .. plugin_name .. "/errors.lua",
    ["kong.plugins." .. plugin_name .. ".sse_usage"] = "kong/plugins/" .. plugin_name .. "/sse_usage.lua",
    ["kong.plugins." .. plugin_name .. ".providers.init"] = "kong/plugins/" .. plugin_name .. "/providers/init.lua",
    ["kong.plugins." .. plugin_name .. ".providers.openai"] = "kong/plugins/" .. plugin_name .. "/providers/openai.lua",
    ["kong.plugins." .. plugin_name .. ".providers.azure"] = "kong/plugins/" .. plugin_name .. "/providers/azure.lua",
    ["kong.plugins." .. plugin_name .. ".providers.anthropic"] = "kong/plugins/" .. plugin_name .. "/providers/anthropic.lua",
    ["kong.plugins." .. plugin_name .. ".providers.bedrock"] = "kong/plugins/" .. plugin_name .. "/providers/bedrock.lua",
    ["kong.plugins." .. plugin_name .. ".providers.gemini"] = "kong/plugins/" .. plugin_name .. "/providers/gemini.lua",
  },
}
