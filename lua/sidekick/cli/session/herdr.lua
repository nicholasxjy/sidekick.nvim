local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Herdr: sidekick.cli.Session
---@field pane_id? string herdr pane id, e.g. `w9:p2`
---@field herdr_agent? boolean whether the pane hosts a herdr agent instead of a regular command
---@field starting? boolean whether herdr is still waiting for the agent to become ready
---@field start_queue? fun()[] actions queued until the agent is ready
local M = {}
M.__index = M

local agent_executables = {
  claude = "claude",
  codex = "codex",
  copilot = "copilot",
  cursor = "cursor-agent",
  gemini = "gemini",
  grok = "grok",
  opencode = "opencode",
  pi = "pi",
}

local function herdr_bin()
  return vim.env.HERDR_BIN_PATH ~= nil and vim.env.HERDR_BIN_PATH ~= "" and vim.env.HERDR_BIN_PATH or "herdr"
end

function M.executable()
  return herdr_bin()
end

---@param cmd string[]
---@param opts? vim.SystemOpts|{notify?:boolean}
local function exec(cmd, opts)
  opts = opts or {}
  table.insert(cmd, 1, herdr_bin())
  return Util.exec(cmd, opts)
end

---@param cmd string[]
---@param opts? vim.SystemOpts|{notify?:boolean}
---@param cb fun(lines?:string[], stdout?:string)
local function exec_async(cmd, opts, cb)
  opts = opts or {}
  table.insert(cmd, 1, herdr_bin())
  Util.exec_async(cmd, opts, cb)
end

---@param cmd string[]
---@return table? decoded JSON response payload
local function exec_json(cmd)
  local lines = exec(cmd, { notify = false })
  if not lines then
    return nil
  end
  local ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  return ok and data or nil
end

---@param data table?
---@return table?
local function result(data)
  return data and data.result or nil
end

---@param cmd string[]
---@param env table<string, string|number|boolean>?
local function add_env(cmd, env)
  local keys = vim.tbl_keys(env or {}) ---@type string[]
  table.sort(keys)
  for _, key in ipairs(keys) do
    local value = env[key]
    if value ~= false then
      vim.list_extend(cmd, { "--env", ("%s=%s"):format(key, tostring(value)) })
    end
  end
end

function M:init()
  if self.started then
    self.external = self.sid ~= self.mux_session
  else
    self.external = vim.env.HERDR_ENV == "1" and Config.cli.mux.create ~= "terminal"
    self.mux_session = self.sid
  end
  self.priority = self.external and 10 or 50
end

--- Create a new pane in herdr, running a shell in `self.cwd`.
---@param kind "tab"|"split" tab = new tab in the current workspace, split = split the current pane
---@return string? pane_id
function M:create_pane(kind)
  local res
  if kind == "tab" then
    local cmd = { "tab", "create", "--cwd", self.cwd, "--label", self.tool.name, "--focus" }
    add_env(cmd, self.tool.env)
    res = result(exec_json(cmd))
  else
    local cmd = { "pane", "split", "--current", "--cwd", self.cwd, "--focus" }
    vim.list_extend(cmd, { "--direction", Config.cli.mux.split.vertical and "right" or "down" })
    local size = Config.cli.mux.split.size
    if type(size) == "number" and size > 0 and size <= 1 then
      vim.list_extend(cmd, { "--ratio", ("%.2f"):format(size) })
    end
    add_env(cmd, self.tool.env)
    res = result(exec_json(cmd))
  end
  local pane = res and (res.pane or res.root_pane) or nil
  return pane and pane.pane_id or nil
end

---@return sidekick.cli.terminal.Cmd?
function M:start()
  if not self.external then
    -- `terminal` mode (or not running inside herdr): just run the tool in a Neovim terminal
    return { cmd = self.tool.cmd, env = self.tool.env }
  end
  local herdr_agent = agent_executables[self.tool.name] == self.tool.cmd[1]
  if not herdr_agent then
    -- `pane run` cannot report when a regular command exits. Keep unsupported
    -- and custom commands in a Neovim terminal where their lifecycle is known.
    return { cmd = self.tool.cmd, env = self.tool.env }
  end
  local kind = Config.cli.mux.create == "window" and "tab" or "split"
  local pane_id = self:create_pane(kind)
  if not pane_id then
    Util.error(("Failed to create a new herdr pane for `%s`"):format(self.tool.name))
    return
  end
  local name = (self.tool.name .. "-" .. pane_id):gsub(":", "-"):lower()
  local cmd = { "agent", "start", name, "--kind", self.tool.name, "--pane", pane_id }
  if #self.tool.cmd > 1 then
    cmd[#cmd + 1] = "--"
    for i = 2, #self.tool.cmd do
      cmd[#cmd + 1] = self.tool.cmd[i]
    end
  end
  self.pane_id = pane_id
  self.herdr_agent = true
  self.id = "herdr " .. pane_id
  self.started = true
  self.starting = true
  exec_async(cmd, { notify = false }, function(lines)
    self.starting = false
    if not lines then
      self.started = false
      self.start_queue = nil
      require("sidekick.cli.session").detach(self)
      exec_async({ "pane", "close", pane_id }, { notify = false }, function() end)
      self.pane_id = nil
      self.herdr_agent = nil
      Util.error(("Failed to start `%s` in herdr pane `%s`"):format(self.tool.name, pane_id))
      return
    end

    exec({ "pane", "rename", pane_id, self.tool.name }, { notify = false })
    Util.info(("Started **%s** in a new herdr %s"):format(self.tool.name, kind == "tab" and "tab" or "split"))
    local queue = self.start_queue or {}
    self.start_queue = nil
    for _, action in ipairs(queue) do
      action()
    end
  end)
end

--- Discover running sidekick tools in herdr panes.
--- herdr reports the detected agent kind on each pane (`pane.agent`),
--- which matches the sidekick tool name for supported tools.
---@return sidekick.cli.session.State[]
function M.sessions()
  local data = exec_json({ "pane", "list" })
  local panes = data and data.result and data.result.panes or {}
  local ret = {} ---@type sidekick.cli.session.State[]
  local tools = Config.tools()
  for _, pane in ipairs(panes) do
    local agent = pane.agent
    if agent and tools[agent] then
      ret[#ret + 1] = {
        id = "herdr " .. pane.pane_id,
        cwd = pane.foreground_cwd or pane.cwd,
        tool = agent,
        pane_id = pane.pane_id,
        herdr_agent = true,
        mux_session = pane.workspace_id,
      }
    end
  end
  return ret
end

function M:attach() end

function M:is_running()
  if not self.pane_id then
    return false
  end
  if self.starting then
    return true
  end
  local resource = self.herdr_agent and "agent" or "pane"
  local data = result(exec_json({ resource, "get", self.pane_id }))
  return data ~= nil and data[resource] ~= nil
end

---Send text to a herdr pane
function M:send(text)
  self:_when_ready(function()
    exec({ "pane", "send-text", self.pane_id, text }, { notify = false })
  end)
end

---Send the Enter key to a herdr pane
function M:submit()
  self:_when_ready(function()
    exec({ "pane", "send-keys", self.pane_id, "Enter" }, { notify = false })
  end)
end

---@param action fun()
function M:_when_ready(action)
  if self.starting then
    self.start_queue = self.start_queue or {}
    self.start_queue[#self.start_queue + 1] = action
  else
    action()
  end
end

function M:dump()
  if not self.pane_id then
    return
  end
  local _, out =
    exec({ "pane", "read", self.pane_id, "--source", "recent", "--lines", tostring(Config.cli.mux.dump), "--format", "text" }, { notify = false })
  return out
end

---Focus a herdr pane
function M:focus()
  self:_when_ready(function()
    if self.pane_id then
      exec({ "agent", "focus", self.pane_id }, { notify = false })
    end
  end)
end

return M
