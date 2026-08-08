---@module 'luassert'

local Config = require("sidekick.config")
local Herdr = require("sidekick.cli.session.herdr")
local Session = require("sidekick.cli.session")
local Util = require("sidekick.util")

describe("herdr session", function()
  local original_exec, original_exec_async
  local original_env, original_bin_path, original_pane_id, original_create, original_split, original_attached
  local original_executable, original_backends, original_did_setup
  local event_group
  local calls = {} ---@type {cmd:string[], opts?:table}[]
  local responses = {} ---@type (string|nil)[]
  local async_calls

  local function tool(name, cmd, env)
    return { name = name, cmd = cmd or { name }, env = env or {} }
  end

  ---@param opts? table
  local function session(opts)
    opts = vim.deepcopy(opts or {})
    opts.tool = opts.tool or tool("codex")
    opts.cwd = opts.cwd or "/tmp/test"
    return setmetatable(opts, Herdr)
  end

  before_each(function()
    original_exec = Util.exec
    original_exec_async = Util.exec_async
    original_env = vim.env.HERDR_ENV
    original_bin_path = vim.env.HERDR_BIN_PATH
    original_pane_id = vim.env.HERDR_PANE_ID
    vim.env.HERDR_ENV = nil
    vim.env.HERDR_BIN_PATH = nil
    original_create = Config.cli.mux.create
    original_split = vim.deepcopy(Config.cli.mux.split)
    original_executable = vim.fn.executable
    original_backends = Session.backends
    original_did_setup = Session.did_setup
    original_attached = Session._attached
    Session._attached = {}
    calls = {}
    responses = {}
    async_calls = 0
    Util.exec = function(cmd, opts)
      table.insert(calls, { cmd = vim.deepcopy(cmd), opts = opts })
      local out = table.remove(responses, 1)
      if out == nil then
        return nil
      end
      return vim.split(out, "\n", { plain = true, trimempty = true }), out
    end
    Util.exec_async = function(cmd, opts, cb)
      async_calls = async_calls + 1
      table.insert(calls, { cmd = vim.deepcopy(cmd), opts = opts })
      local out = table.remove(responses, 1)
      if out == nil then
        cb()
      else
        cb(vim.split(out, "\n", { plain = true, trimempty = true }), out)
      end
    end
  end)

  after_each(function()
    Util.exec = original_exec
    Util.exec_async = original_exec_async
    vim.env.HERDR_ENV = original_env
    vim.env.HERDR_BIN_PATH = original_bin_path
    vim.env.HERDR_PANE_ID = original_pane_id
    Config.cli.mux.create = original_create
    Config.cli.mux.split = original_split
    vim.fn.executable = original_executable
    Session.backends = original_backends
    Session.did_setup = original_did_setup
    Session._attached = original_attached
    if event_group then
      pcall(vim.api.nvim_del_augroup_by_id, event_group)
      event_group = nil
    end
  end)

  local function json(payload)
    return vim.json.encode({ id = "cli:test", result = payload, type = "test" })
  end

  it("uses HERDR_BIN_PATH when configured", function()
    vim.env.HERDR_BIN_PATH = "/tmp/custom-herdr"
    assert.are.same("/tmp/custom-herdr", Herdr.executable())
  end)

  it("registers herdr with a configured binary path", function()
    vim.env.HERDR_BIN_PATH = "/tmp/custom-herdr"
    Session.backends = {}
    Session.did_setup = false
    vim.fn.executable = function(command)
      return command == "/tmp/custom-herdr" and 1 or 0
    end

    Session.setup()

    assert.are.same(Herdr, Session.backends.herdr)
  end)

  describe("sessions()", function()
    it("discovers panes with known agents only", function()
      responses[1] = json({
        panes = {
          { pane_id = "w9:p2", agent = "pi", name = "pi-w9-p2", foreground_cwd = "/a", cwd = "/a", workspace_id = "w9" },
          { pane_id = "w7:p4", agent = "codex", foreground_cwd = "/b", cwd = "/b", workspace_id = "w7" },
          -- plain shell pane, no agent
          { pane_id = "w7:p1", agent_status = "unknown", foreground_cwd = "/c", cwd = "/c", workspace_id = "w7" },
          -- herdr agent without a sidekick tool config
          { pane_id = "w1:p1", agent = "devin", foreground_cwd = "/d", cwd = "/d", workspace_id = "w1" },
        },
      })

      local states = Herdr.sessions()

      assert.are.same(2, #states)
      assert.are.same("herdr w9:p2", states[1].id)
      assert.are.same("pi", states[1].tool)
      assert.are.same("/a", states[1].cwd)
      assert.are.same("w9:p2", states[1].pane_id)
      assert.is_true(states[1].herdr_agent)
      assert.are.same("w9", states[1].mux_session)
      assert.are.same("herdr w7:p4", states[2].id)
      assert.are.same("codex", states[2].tool)
    end)

    it("returns no sessions when the server is unavailable", function()
      assert.are.same({}, Herdr.sessions())
    end)
  end)

  describe("init()", function()
    it("marks sessions external when inside herdr and not terminal mode", function()
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "split"
      local s = session()
      s:init()
      assert.is_true(s.external)
      assert.are.same(10, s.priority)
    end)

    it("stays embedded when not inside herdr", function()
      Config.cli.mux.create = "split"
      local s = session()
      s:init()
      assert.is_false(s.external)
      assert.are.same(50, s.priority)
    end)

    it("stays embedded in terminal mode inside herdr", function()
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "terminal"
      local s = session()
      s:init()
      assert.is_false(s.external)
    end)
  end)

  describe("start()", function()
    it("runs the tool directly in terminal mode", function()
      Config.cli.mux.create = "terminal"
      local s = session()
      s:init()
      local cmd = s:start()
      assert.are.same({ cmd = { "codex" }, env = {} }, cmd)
    end)

    it("splits the current pane and runs the tool in split mode", function()
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "split"
      responses[1] = json({ pane = { pane_id = "w9:p9" } })
      responses[2] = json({})

      local s = session()
      s:init()
      local cmd = s:start()

      assert.is_nil(cmd) -- external session, no Neovim terminal
      assert.is_true(s.started)
      assert.is_false(s.starting)
      assert.is_true(s.herdr_agent)
      assert.are.same(1, async_calls)
      assert.are.same("w9:p9", s.pane_id)
      assert.are.same("herdr w9:p9", s.id)
      assert.are.same({ "herdr", "pane", "split", "--current", "--cwd", "/tmp/test", "--focus", "--direction", "right", "--ratio", "0.50" }, calls[1].cmd)
      assert.are.same({ "herdr", "agent", "start", "codex-w9-p9", "--kind", "codex", "--pane", "w9:p9" }, calls[2].cmd)
      assert.are.same({ "herdr", "pane", "rename", "w9:p9", "codex" }, calls[3].cmd)
    end)

    it("does not wait for herdr to finish starting the agent", function()
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "split"
      responses[1] = json({ pane = { pane_id = "w9:p9" } })
      local done
      Util.exec_async = function(cmd, opts, cb)
        table.insert(calls, { cmd = vim.deepcopy(cmd), opts = opts })
        done = cb
      end

      local s = session()
      s:init()
      s:start()

      assert.is_true(s.started)
      assert.is_true(s.starting)
      assert.is_true(s:is_running())
      assert.is_function(done)
      assert.are.same(2, #calls)
      s:send("first prompt")
      s:submit()
      s:focus()
      assert.are.same(2, #calls)
      done({ json({}) }, json({}))
      assert.is_false(s.starting)
      assert.are.same({ "herdr", "pane", "rename", "w9:p9", "codex" }, calls[3].cmd)
      assert.are.same({ "herdr", "pane", "send-text", "w9:p9", "first prompt" }, calls[4].cmd)
      assert.are.same({ "herdr", "pane", "send-keys", "w9:p9", "Enter" }, calls[5].cmd)
      assert.are.same({ "herdr", "agent", "focus", "w9:p9" }, calls[6].cmd)
    end)

    it("stays attached while the status handler checks a starting agent", function()
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "split"
      responses[1] = json({ pane = { pane_id = "w9:p9" } })
      local done
      Util.exec_async = function(cmd, opts, cb)
        table.insert(calls, { cmd = vim.deepcopy(cmd), opts = opts })
        done = cb
      end
      event_group = vim.api.nvim_create_augroup("sidekick_test_herdr_start", { clear = true })
      vim.api.nvim_create_autocmd("User", {
        group = event_group,
        pattern = "SidekickCliAttach",
        callback = function() Session.attached() end,
      })

      local s = session()
      s:init()
      Session.attach(s)

      assert.are.same(s, Session._attached[s.id])
      assert.is_true(s.starting)
      assert.are.same(2, #calls) -- status refresh must not run `agent get` yet
      Session.backends = { herdr = Herdr }
      Session.did_setup = true
      assert.are.same({ s }, Session.sessions())
      assert.are.same(s, Session._attached[s.id])
      done({ json({}) }, json({}))
      assert.is_false(s.starting)
    end)

    it("clears the running state when asynchronous agent startup fails", function()
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "split"
      responses[1] = json({ pane = { pane_id = "w9:p9" } })
      local done
      Util.exec_async = function(cmd, opts, cb)
        table.insert(calls, { cmd = vim.deepcopy(cmd), opts = opts })
        if cmd[2] == "agent" then
          done = cb
        else
          cb({})
        end
      end

      local s = session()
      s:init()
      s:start()
      done()

      assert.is_false(s.started)
      assert.is_false(s.starting)
      assert.is_nil(s.pane_id)
      assert.are.same({ "herdr", "pane", "close", "w9:p9" }, calls[3].cmd)
    end)

    it("uses a horizontal split when split.vertical is false", function()
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "split"
      Config.cli.mux.split.vertical = false
      responses[1] = json({ pane = { pane_id = "w9:p9" } })
      responses[2] = json({})

      local s = session()
      s:init()
      s:start()

      assert.are.same({ "herdr", "pane", "split", "--current", "--cwd", "/tmp/test", "--focus", "--direction", "down", "--ratio", "0.50" }, calls[1].cmd)
    end)

    it("passes env vars to the new pane and skips unset values", function()
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "split"
      responses[1] = json({ pane = { pane_id = "w9:p9" } })
      responses[2] = json({})

      local s = session({ tool = tool("opencode", { "opencode" }, { OPENCODE_THEME = "system", NOPE = false }) })
      s:init()
      s:start()

      assert.are.same({
        "herdr", "pane", "split", "--current", "--cwd", "/tmp/test", "--focus", "--direction", "right",
        "--ratio", "0.50", "--env", "OPENCODE_THEME=system",
      }, calls[1].cmd)
      assert.are.same({ "herdr", "agent", "start", "opencode-w9-p9", "--kind", "opencode", "--pane", "w9:p9" }, calls[2].cmd)
    end)

    it("passes tool arguments to herdr agent start", function()
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "split"
      responses[1] = json({ pane = { pane_id = "w9:p9" } })
      responses[2] = json({})

      local s = session({ tool = tool("copilot", { "copilot", "--banner" }) })
      s:init()
      s:start()

      assert.are.same({
        "herdr", "agent", "start", "copilot-w9-p9", "--kind", "copilot", "--pane", "w9:p9", "--", "--banner",
      }, calls[2].cmd)
    end)

    it("runs unsupported tools in a Neovim terminal", function()
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "split"

      local s = session({ tool = tool("aider", { "aider" }, { THEME = "dark" }) })
      s:init()
      local cmd = s:start()

      assert.are.same({ cmd = { "aider" }, env = { THEME = "dark" } }, cmd)
      assert.is_nil(s.started)
      assert.are.same({}, calls)
    end)

    it("creates a new tab in window mode", function()
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "window"
      responses[1] = json({ tab = { tab_id = "w9:t2" }, root_pane = { pane_id = "w9:p9" } })
      responses[2] = json({})

      local s = session()
      s:init()
      s:start()

      assert.are.same({ "herdr", "tab", "create", "--cwd", "/tmp/test", "--label", "codex", "--focus" }, calls[1].cmd)
      assert.are.same({ "herdr", "agent", "start", "codex-w9-p9", "--kind", "codex", "--pane", "w9:p9" }, calls[2].cmd)
    end)

    it("passes env vars when creating a tab", function()
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "window"
      responses[1] = json({ tab = { tab_id = "w9:t2" }, root_pane = { pane_id = "w9:p9" } })
      responses[2] = json({})

      local s = session({ tool = tool("pi", { "pi" }, { NOPE = false, PI_THEME = "dark" }) })
      s:init()
      s:start()

      assert.are.same({
        "herdr", "tab", "create", "--cwd", "/tmp/test", "--label", "pi", "--focus", "--env", "PI_THEME=dark",
      }, calls[1].cmd)
    end)

    it("does not reuse the focused Neovim pane when create returns no pane", function()
      vim.env.HERDR_ENV = "1"
      vim.env.HERDR_PANE_ID = "w1:p1"
      Config.cli.mux.create = "split"
      responses[1] = json({})

      local s = session()
      s:init()
      s:start()

      assert.is_nil(s.pane_id)
      assert.is_nil(s.started)
      assert.are.same(1, #calls)
    end)

    it("does not mark the session as started when the pane cannot be created", function()
      vim.env.HERDR_ENV = "1"
      Config.cli.mux.create = "split"
      local s = session()
      s:init()
      local cmd = s:start()
      assert.is_nil(cmd)
      assert.is_nil(s.started)
    end)
  end)

  describe("actions", function()
    it("sends text and submit with pane commands", function()
      local s = session({ pane_id = "w9:p2" })
      s:send("hello\nworld")
      s:submit()
      assert.are.same({ "herdr", "pane", "send-text", "w9:p2", "hello\nworld" }, calls[1].cmd)
      assert.are.same({ "herdr", "pane", "send-keys", "w9:p2", "Enter" }, calls[2].cmd)
    end)

    it("focuses the pane with the agent command", function()
      local s = session({ pane_id = "w9:p2" })
      s:focus()
      assert.are.same({ "herdr", "agent", "focus", "w9:p2" }, calls[1].cmd)
    end)

    it("dumps the recent pane output", function()
      local s = session({ pane_id = "w9:p2" })
      responses[1] = "line1\nline2"
      local out = s:dump()
      assert.are.same("line1\nline2", out)
      assert.are.same({ "herdr", "pane", "read", "w9:p2", "--source", "recent", "--lines", "2000", "--format", "text" }, calls[1].cmd)
    end)

    it("checks agent liveness with agent get", function()
      local s = session({ pane_id = "w9:p2", herdr_agent = true })
      responses[1] = json({ agent = { pane_id = "w9:p2" } })
      assert.is_true(s:is_running())
      assert.is_false(s:is_running()) -- next response fails
      assert.are.same({ "herdr", "agent", "get", "w9:p2" }, calls[1].cmd)
    end)

    it("checks regular process liveness with pane get", function()
      local s = session({ pane_id = "w9:p2" })
      responses[1] = json({ pane = { pane_id = "w9:p2" } })
      assert.is_true(s:is_running())
      assert.are.same({ "herdr", "pane", "get", "w9:p2" }, calls[1].cmd)
      local s2 = session({})
      assert.is_false(s2:is_running()) -- no pane_id
    end)
  end)
end)
