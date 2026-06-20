---@module 'luassert'

local Select = require("sidekick.cli.ui.select")
local State = require("sidekick.cli.state")

describe("cli ui select", function()
  local original_get
  local original_ui_select

  before_each(function()
    original_get = State.get
    original_ui_select = vim.ui.select
  end)

  after_each(function()
    State.get = original_get
    vim.ui.select = original_ui_select
  end)

  it("passes snacks options to vim.ui.select", function()
    local select_opts
    State.get = function()
      return {
        { tool = { name = "claude" }, installed = true },
        { tool = { name = "codex" }, installed = true },
      }
    end
    vim.ui.select = function(_, opts)
      select_opts = opts
    end

    Select.select({
      cb = function() end,
      snacks = {
        layout = { preset = "dropdown" },
        win = { input = { keys = { ["<c-x>"] = "close" } } },
      },
    })

    assert.are.same({ preset = "dropdown" }, select_opts.snacks.layout)
    assert.are.same({ ["<c-x>"] = "close" }, select_opts.snacks.win.input.keys)
    assert.are.equal(Select.format, select_opts.snacks.format)
  end)
end)
