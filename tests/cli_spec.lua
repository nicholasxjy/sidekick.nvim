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

  it("focuses the session after sending", function()
    local calls = {}
    State.with = function(cb, opts)
      assert.is_false(opts.focus)
      cb({
        tool = {
          format = function(_, text)
            return text[1][1]
          end,
        },
        session = {
          send = function(_, text)
            calls[#calls + 1] = "send " .. text
          end,
          submit = function()
            calls[#calls + 1] = "submit"
          end,
          focus = function()
            calls[#calls + 1] = "focus"
          end,
        },
      })
    end

    Cli.send({ text = { { "buffer" } }, submit = true })
    assert(vim.wait(100, function() return #calls == 3 end))
    assert.are.same({ "send buffer\n", "submit", "focus" }, calls)
  end)
end)
