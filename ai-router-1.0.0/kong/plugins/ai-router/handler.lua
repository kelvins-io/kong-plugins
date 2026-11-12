-- AI Router：对齐 LiteLLM Router 的模型路由 / 负载均衡 / 重试 / Fallback。
-- access 阶段直接调用 Provider 并返回（短路 Kong 上游代理）。
local access = require "kong.plugins.ai-router.access"
local analytics = require "kong.plugins.ai-router.analytics"

local AiRouterHandler = {
  VERSION  = "1.0.0",
  PRIORITY = 770,
}


function AiRouterHandler:access(conf)
  access.execute(conf)
end


function AiRouterHandler:log(conf)
  analytics.log(conf)
end


return AiRouterHandler
