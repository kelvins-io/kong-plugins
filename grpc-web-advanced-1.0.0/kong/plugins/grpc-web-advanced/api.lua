---
--- Admin API：删除 proto 本地缓存目录中的 .proto 文件
--- DELETE 时广播到集群所有节点，各节点本地执行删除
---

local proto_loader = require "kong.plugins.grpc-web-advanced.proto_loader"
local kong = kong

local CLUSTER_EVENT = "grpc-web-advanced:proto-cache-purge"

local function broadcast_purge(payload)
  kong.log.debug("broadcasting proto cache purge: ", payload)
  return kong.cluster_events:broadcast(CLUSTER_EVENT, payload)
end

local function each_grpc_web_advanced_plugin()
  local iter = kong.db.plugins:each()
  return function()
    while true do
      local plugin, err = iter()
      if err then
        kong.response.exit(500, { message = err })
        return
      end
      if not plugin then
        return
      end
      if plugin.name == "grpc-web-advanced" then
        return plugin
      end
    end
  end
end

return {
  ["/grpc-web-advanced/proto-cache"] = {
    resource = "grpc-web-advanced-proto-cache",

    --- 删除所有 grpc-web-advanced 插件的 proto 缓存
    DELETE = function()
      local seen = {}
      local total = 0

      for plugin in each_grpc_web_advanced_plugin() do
        local cache_dir = proto_loader.get_cache_root(plugin.config)
        if not seen[cache_dir] then
          seen[cache_dir] = true
          local count, err = proto_loader.purge_cache_dir(cache_dir)
          if err then
            return kong.response.exit(500, { message = err })
          end
          total = total + (count or 0)
        end
      end

      local ok, err = broadcast_purge("all")
      if not ok then
        kong.log.err("failed broadcasting proto cache purge to cluster: ", err)
      end

      return kong.response.exit(200, {
        deleted = total,
        message = "purged " .. total .. " proto file(s)",
      })
    end,
  },

  ["/grpc-web-advanced/proto-cache/:plugin_id"] = {
    resource = "grpc-web-advanced-proto-cache",

    --- 删除指定插件的 proto 缓存
    DELETE = function(self)
      local plugin, err = kong.db.plugins:select({
        id = self.params.plugin_id,
      })
      if err then
        return kong.response.exit(500, { message = err })
      end
      if not plugin then
        return kong.response.exit(404, { message = "plugin not found" })
      end
      if plugin.name ~= "grpc-web-advanced" then
        return kong.response.exit(404, { message = "plugin is not grpc-web-advanced" })
      end

      local cache_dir = proto_loader.get_cache_root(plugin.config)
      local count, purge_err = proto_loader.purge_cache_dir(cache_dir)
      if purge_err then
        return kong.response.exit(500, { message = purge_err })
      end

      local ok, err = broadcast_purge(self.params.plugin_id)
      if not ok then
        kong.log.err("failed broadcasting proto cache purge to cluster: ", err)
      end

      return kong.response.exit(200, {
        deleted = count or 0,
        message = "purged " .. (count or 0) .. " proto file(s)",
      })
    end,
  },
}
