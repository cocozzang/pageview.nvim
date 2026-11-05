local async = require("pageview.async")

describe("async", function()
  it("awaits callbacks called later", function()
    local result
    async.run(function()
      local v = async.await(function(cb)
        vim.defer_fn(function()
          cb(nil, 42)
        end, 10)
      end)
      result = v
    end)
    assert.is_true(vim.wait(1000, function()
      return result ~= nil
    end))
    assert.are.equal(42, result)
  end)

  it("awaits callbacks called right away", function()
    local result
    async.run(function()
      result = async.await(function(cb)
        cb(nil, "now")
      end)
    end)
    assert.are.equal("now", result)
  end)

  it("raises callback errors and reports them to done", function()
    local err
    async.run(function()
      async.await(function(cb)
        cb("boom")
      end)
    end, function(e)
      err = e
    end)
    assert.matches("boom", err)
  end)

  it("passes return values to done", function()
    local got
    async.run(function()
      return 1, 2
    end, function(_, a, b)
      got = { a, b }
    end)
    assert.are.same({ 1, 2 }, got)
  end)
end)
