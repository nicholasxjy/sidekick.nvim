---@module 'luassert'

local Cli = require("sidekick.cli")
local State = require("sidekick.cli.state")

describe("cli", function()
  local original_with

  before_each(function()
    original_with = State.with
  end)

  after_each(function()
    State.with = original_with
  end)

  it("passes snacks options from toggle to selection", function()
    local with_opts
    State.with = function(_, opts)
      with_opts = opts
    end

    Cli.toggle({
      snacks = {
        layout = { preset = "dropdown" },
      },
    })

    assert.are.same({ preset = "dropdown" }, with_opts.snacks.layout)
  end)
end)
