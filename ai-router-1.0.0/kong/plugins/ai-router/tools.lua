-- OpenAI tools / tool_calls ↔ Anthropic / Bedrock / Gemini 互转。
local cjson = require "cjson.safe"

local type = type
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local concat = table.concat


local _M = {}


function _M.content_to_text(content)
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return tostring(content or "")
  end
  local parts = {}
  for i = 1, #content do
    local part = content[i]
    if type(part) == "string" then
      parts[#parts + 1] = part
    elseif type(part) == "table" then
      if part.type == "text" and part.text then
        parts[#parts + 1] = part.text
      elseif part.text then
        parts[#parts + 1] = part.text
      end
    end
  end
  return concat(parts, "\n")
end


function _M.decode_args(raw)
  if type(raw) == "table" then
    return raw
  end
  if type(raw) ~= "string" or raw == "" then
    return {}
  end
  local obj = cjson.decode(raw)
  if type(obj) == "table" then
    return obj
  end
  return { value = raw }
end


function _M.encode_args(obj)
  if type(obj) == "string" then
    return obj
  end
  return cjson.encode(obj or {}) or "{}"
end


--- OpenAI tools[] → Anthropic tools[]
function _M.openai_tools_to_anthropic(tools)
  if type(tools) ~= "table" or #tools == 0 then
    return nil
  end
  local out = {}
  for _, t in ipairs(tools) do
    local fn = (type(t) == "table" and (t["function"] or t)) or {}
    if fn.name then
      out[#out + 1] = {
        name = fn.name,
        description = fn.description or "",
        input_schema = fn.parameters or { type = "object", properties = {} },
      }
    end
  end
  return #out > 0 and out or nil
end


function _M.openai_tool_choice_to_anthropic(choice)
  if choice == nil then
    return nil
  end
  if choice == "auto" then
    return { type = "auto" }
  end
  if choice == "none" then
    return { type = "auto" } -- anthropic has no none; omit tools instead at caller
  end
  if choice == "required" then
    return { type = "any" }
  end
  if type(choice) == "table" then
    local fn = choice["function"]
    local name = (fn and fn.name)
      or (choice.type == "function" and fn and fn.name)
      or choice.name
    if name then
      return { type = "tool", name = name }
    end
  end
  return { type = "auto" }
end


--- OpenAI tools → Bedrock toolConfig.tools
function _M.openai_tools_to_bedrock(tools)
  if type(tools) ~= "table" or #tools == 0 then
    return nil
  end
  local out = {}
  for _, t in ipairs(tools) do
    local fn = (type(t) == "table" and (t["function"] or t)) or {}
    if fn.name then
      out[#out + 1] = {
        toolSpec = {
          name = fn.name,
          description = fn.description or "",
          inputSchema = {
            json = fn.parameters or { type = "object", properties = {} },
          },
        },
      }
    end
  end
  return #out > 0 and out or nil
end


function _M.openai_tool_choice_to_bedrock(choice)
  if choice == nil or choice == "auto" then
    return { auto = {} }
  end
  if choice == "none" then
    return nil
  end
  if choice == "required" then
    return { any = {} }
  end
  if type(choice) == "table" then
    local fn = choice["function"]
    local name = (fn and fn.name) or choice.name
    if name then
      return { tool = { name = name } }
    end
  end
  return { auto = {} }
end


--- OpenAI tools → Gemini functionDeclarations
function _M.openai_tools_to_gemini(tools)
  if type(tools) ~= "table" or #tools == 0 then
    return nil
  end
  local decls = {}
  for _, t in ipairs(tools) do
    local fn = (type(t) == "table" and (t["function"] or t)) or {}
    if fn.name then
      decls[#decls + 1] = {
        name = fn.name,
        description = fn.description or "",
        parameters = fn.parameters or { type = "object", properties = {} },
      }
    end
  end
  if #decls == 0 then
    return nil
  end
  return { { functionDeclarations = decls } }
end


function _M.openai_tool_choice_to_gemini(choice)
  if choice == nil or choice == "auto" then
    return { functionCallingConfig = { mode = "AUTO" } }
  end
  if choice == "none" then
    return { functionCallingConfig = { mode = "NONE" } }
  end
  if choice == "required" then
    return { functionCallingConfig = { mode = "ANY" } }
  end
  if type(choice) == "table" then
    local fn = choice["function"]
    local name = (fn and fn.name) or choice.name
    if name then
      return {
        functionCallingConfig = {
          mode = "ANY",
          allowedFunctionNames = { name },
        },
      }
    end
  end
  return { functionCallingConfig = { mode = "AUTO" } }
end


--- Build OpenAI assistant message tool_calls from Anthropic content blocks
function _M.anthropic_tool_uses_to_openai(content)
  local tool_calls = {}
  local text_parts = {}
  for _, block in ipairs(content or {}) do
    if type(block) ~= "table" then
      -- skip
    elseif block.type == "text" and block.text then
      text_parts[#text_parts + 1] = block.text
    elseif block.type == "tool_use" then
      tool_calls[#tool_calls + 1] = {
        id = block.id or ("call_" .. tostring(#tool_calls + 1)),
        type = "function",
        ["function"] = {
          name = block.name,
          arguments = _M.encode_args(block.input),
        },
      }
    end
  end
  return concat(text_parts, ""), tool_calls
end


--- Bedrock content blocks → text + OpenAI tool_calls
function _M.bedrock_tool_uses_to_openai(content)
  local tool_calls = {}
  local text_parts = {}
  for _, block in ipairs(content or {}) do
    if type(block) ~= "table" then
      -- skip
    elseif block.text then
      text_parts[#text_parts + 1] = block.text
    elseif block.toolUse then
      local tu = block.toolUse
      tool_calls[#tool_calls + 1] = {
        id = tu.toolUseId or ("call_" .. tostring(#tool_calls + 1)),
        type = "function",
        ["function"] = {
          name = tu.name,
          arguments = _M.encode_args(tu.input),
        },
      }
    end
  end
  return concat(text_parts, ""), tool_calls
end


--- Gemini parts → text + OpenAI tool_calls
function _M.gemini_parts_to_openai(parts)
  local tool_calls = {}
  local text_parts = {}
  for _, part in ipairs(parts or {}) do
    if type(part) ~= "table" then
      -- skip
    elseif part.text and not part.thought then
      text_parts[#text_parts + 1] = part.text
    elseif part.functionCall then
      local fc = part.functionCall
      tool_calls[#tool_calls + 1] = {
        id = "call_" .. tostring(#tool_calls + 1),
        type = "function",
        ["function"] = {
          name = fc.name,
          arguments = _M.encode_args(fc.args or {}),
        },
      }
    end
  end
  return concat(text_parts, ""), tool_calls
end


--- Convert OpenAI messages (with tool_calls / tool role) → Anthropic messages + system
function _M.openai_messages_to_anthropic(messages)
  local system_parts = {}
  local out = {}

  for _, m in ipairs(messages or {}) do
    local role = m.role
    if role == "system" then
      system_parts[#system_parts + 1] = _M.content_to_text(m.content)
    elseif role == "user" then
      out[#out + 1] = {
        role = "user",
        content = {
          { type = "text", text = _M.content_to_text(m.content) },
        },
      }
    elseif role == "assistant" then
      local blocks = {}
      local text = _M.content_to_text(m.content)
      if text and text ~= "" then
        blocks[#blocks + 1] = { type = "text", text = text }
      end
      if type(m.tool_calls) == "table" then
        for _, tc in ipairs(m.tool_calls) do
          local fn = tc["function"] or {}
          blocks[#blocks + 1] = {
            type = "tool_use",
            id = tc.id or ("toolu_" .. tostring(#blocks)),
            name = fn.name,
            input = _M.decode_args(fn.arguments),
          }
        end
      end
      if #blocks > 0 then
        out[#out + 1] = { role = "assistant", content = blocks }
      end
    elseif role == "tool" then
      out[#out + 1] = {
        role = "user",
        content = {
          {
            type = "tool_result",
            tool_use_id = m.tool_call_id or m.id or "toolu_unknown",
            content = _M.content_to_text(m.content),
          },
        },
      }
    end
  end

  local system
  if #system_parts > 0 then
    system = concat(system_parts, "\n")
  end
  return out, system
end


--- OpenAI messages → Bedrock Converse messages + system
function _M.openai_messages_to_bedrock(messages)
  local system = {}
  local out = {}

  for _, m in ipairs(messages or {}) do
    local role = m.role
    if role == "system" or role == "developer" then
      system[#system + 1] = { text = _M.content_to_text(m.content) }
    elseif role == "user" then
      out[#out + 1] = {
        role = "user",
        content = { { text = _M.content_to_text(m.content) } },
      }
    elseif role == "assistant" then
      local content = {}
      local text = _M.content_to_text(m.content)
      if text and text ~= "" then
        content[#content + 1] = { text = text }
      end
      if type(m.tool_calls) == "table" then
        for _, tc in ipairs(m.tool_calls) do
          local fn = tc["function"] or {}
          content[#content + 1] = {
            toolUse = {
              toolUseId = tc.id or ("tooluse_" .. tostring(#content)),
              name = fn.name,
              input = _M.decode_args(fn.arguments),
            },
          }
        end
      end
      if #content > 0 then
        out[#out + 1] = { role = "assistant", content = content }
      end
    elseif role == "tool" then
      out[#out + 1] = {
        role = "user",
        content = {
          {
            toolResult = {
              toolUseId = m.tool_call_id or "tooluse_unknown",
              content = { { text = _M.content_to_text(m.content) } },
            },
          },
        },
      }
    end
  end

  return out, (#system > 0 and system or nil)
end


--- OpenAI messages → Gemini contents + systemInstruction
function _M.openai_messages_to_gemini(messages)
  local system_parts = {}
  local contents = {}
  local pending_tool_responses = {}

  local function flush_tool_responses()
    if #pending_tool_responses == 0 then
      return
    end
    contents[#contents + 1] = {
      role = "user",
      parts = pending_tool_responses,
    }
    pending_tool_responses = {}
  end

  for _, m in ipairs(messages or {}) do
    local role = m.role
    if role == "system" then
      system_parts[#system_parts + 1] = { text = _M.content_to_text(m.content) }
    elseif role == "user" then
      flush_tool_responses()
      contents[#contents + 1] = {
        role = "user",
        parts = { { text = _M.content_to_text(m.content) } },
      }
    elseif role == "assistant" then
      flush_tool_responses()
      local parts = {}
      local text = _M.content_to_text(m.content)
      if text and text ~= "" then
        parts[#parts + 1] = { text = text }
      end
      if type(m.tool_calls) == "table" then
        for _, tc in ipairs(m.tool_calls) do
          local fn = tc["function"] or {}
          parts[#parts + 1] = {
            functionCall = {
              name = fn.name,
              args = _M.decode_args(fn.arguments),
            },
          }
        end
      end
      if #parts > 0 then
        contents[#contents + 1] = { role = "model", parts = parts }
      end
    elseif role == "tool" then
      pending_tool_responses[#pending_tool_responses + 1] = {
        functionResponse = {
          name = m.name or "tool",
          response = { content = _M.content_to_text(m.content) },
        },
      }
    end
  end
  flush_tool_responses()

  local systemInstruction
  if #system_parts > 0 then
    systemInstruction = { parts = system_parts }
  end
  return contents, systemInstruction
end


function _M.finish_reason_from_tool_calls(tool_calls, fallback)
  if type(tool_calls) == "table" and #tool_calls > 0 then
    return "tool_calls"
  end
  return fallback or "stop"
end


return _M
