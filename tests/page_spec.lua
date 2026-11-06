-- Page features, checked in a real headless browser: a document is laid out in
-- the page shell and the resulting DOM is inspected.
-- Skipped when no Chromium-based browser is installed.

local async = require("pageview.async")
local browser = require("pageview.browser")
local config = require("pageview.config")
local render = require("pageview.render")

local it_browser = browser.find() and it or pending
local fixtures = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fixtures")

local runs = 0

--- Lay `src` out in the page shell, then evaluate the JavaScript expression
--- `js` in the page (a promise is awaited) and return its value.
---@param src string
---@param js string
---@param over? table render params to override
---@return any
local function page(src, js, over)
  runs = runs + 1
  ---@type pageview.RenderParams
  local p = vim.tbl_extend("force", {
    src = src,
    base_href = vim.uri_from_fname(fixtures) .. "/",
    cols = 100,
    win_rows = 30,
    cell_width = 16,
    cell_height = 32,
    zoom = 1,
    theme = "github-dark",
    background = "page",
  }, over or {})
  local value, err, done
  async.run(function()
    browser.with(function(b)
      render.layout(b, p, "page-spec-" .. runs)
      local res = browser.call(b, "Runtime.evaluate", {
        expression = js,
        awaitPromise = true,
        returnByValue = true,
      })
      if res.exceptionDetails then
        error(vim.inspect(res.exceptionDetails), 0)
      end
      value = res.result.value
    end)
  end, function(e)
    err, done = e, true
  end)
  assert.is_true(vim.wait(30000, function()
    return done
  end, 10))
  assert.is_nil(err)
  return value
end

---@param name string
---@return string
local function fixture(name)
  return table.concat(vim.fn.readfile(fixtures .. "/" .. name), "\n")
end

describe("page", function()
  setup(function()
    config.setup({ browser_args = vim.fn.has("linux") == 1 and { "--no-sandbox" } or {} })
  end)

  teardown(function()
    browser.shutdown(true)
  end)

  it_browser("renders the showcase document", function()
    local n = page(fixture("showcase.md"), "document.querySelectorAll('#root h2').length")
    assert.is_true(n >= 8)
  end)

  it_browser("resolves relative image paths against the document folder", function()
    local width = page("![dot](dot.svg)", "document.querySelector('#root img').naturalWidth")
    assert.are.equal(40, width)
  end)

  describe("code blocks", function()
    local count = "document.querySelectorAll('#root pre code span[class^=hljs-]').length"
    local keyword_color = "getComputedStyle(document.querySelector('#root .hljs-keyword')).color"

    it_browser("are colored by language", function()
      assert.is_true(page("```lua\nlocal x = 1 -- one\n```", count) > 0)
    end)

    it_browser("accept GitHub's names for Vim script", function()
      assert.is_true(page("```viml\nset number\n```", count) > 0)
    end)

    it_browser("stay plain without a known language", function()
      assert.are.equal(0, page("```nope\nlocal x = 1\n```\n\n```\nlocal x = 1\n```", count))
    end)

    it_browser("follow the theme", function()
      local src = "```lua\nlocal x = 1\n```"
      assert.are.equal("rgb(255, 123, 114)", page(src, keyword_color, { theme = "github-dark" }))
      assert.are.equal("rgb(215, 58, 73)", page(src, keyword_color, { theme = "github-light" }))
    end)
  end)

  it_browser("renders task lists as checkboxes", function()
    local boxes = page(
      "- [ ] todo\n- [x] done\n- plain",
      "[...document.querySelectorAll('#root li.task-list-item > input.task-list-item-checkbox')]"
        .. ".map((c) => c.checked && c.disabled ? 'checked' : c.disabled ? 'empty' : 'enabled')"
    )
    assert.are.same({ "empty", "checked" }, boxes)
  end)

  it_browser("renders footnotes with GitHub's markup", function()
    local got = page(
      "Text[^a] and more[^a].\n\n[^a]: The note.",
      [[(() => {
        const refs = [...document.querySelectorAll('#root sup > a[data-footnote-ref]')];
        const section = document.querySelector('#root section.footnotes[data-footnotes]');
        return {
          refs: refs.map((a) => a.textContent),
          before: getComputedStyle(refs[0], '::before').content,
          note: section.querySelector('li p').firstChild.textContent.trim(),
          backrefs: section.querySelectorAll('a.data-footnote-backref').length,
          rules: document.querySelectorAll('#root hr').length,
        };
      })()]]
    )
    assert.are.same({ refs = { "1", "1" }, before = '"["', note = "The note.", backrefs = 2, rules = 0 }, got)
  end)

  it_browser("renders GitHub alerts", function()
    local src = table.concat({
      "> [!NOTE]\n> Useful.",
      "> [!warning]\n>\n> Careful.\n>\n> More.",
      "> [!TIP] not on its own line",
      "> [!CAUTION]",
      "> A plain quote.",
      "- > [!NOTE]\n  > Inside a list.",
    }, "\n\n")
    local got = page(
      src,
      [[(() => ({
        alerts: [...document.querySelectorAll('#root div.markdown-alert')].map((d) => [
          d.className,
          d.querySelector('p.markdown-alert-title').textContent,
          d.querySelectorAll('p.markdown-alert-title > svg.octicon').length,
          [...d.querySelectorAll('p:not(.markdown-alert-title)')].map((p) => p.textContent),
        ]),
        quotes: document.querySelectorAll('#root blockquote').length,
      }))()]]
    )
    assert.are.same({
      alerts = {
        { "markdown-alert markdown-alert-note", "Note", 1, { "Useful." } },
        { "markdown-alert markdown-alert-warning", "Warning", 1, { "Careful.", "More." } },
      },
      quotes = 4,
    }, got)
  end)

  it_browser("removes scripts and event handlers from inline HTML", function()
    local html = page(
      '<img src="dot.svg" onerror="alert(1)"><script>alert(2)</script>',
      "document.getElementById('root').innerHTML"
    )
    assert.is_nil(html:find("onerror", 1, true))
    assert.is_nil(html:find("<script", 1, true))
  end)
end)
