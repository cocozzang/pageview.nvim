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

  it_browser("turns emoji shortcodes into emoji", function()
    local text = page("Ship it :tada: :) :not_an_emoji: `:tada:`", "document.querySelector('#root p').textContent")
    assert.are.equal("Ship it 🎉 :) :not_an_emoji: :tada:", text)
  end)

  describe("math", function()
    local counts = [[({
      inline: document.querySelectorAll('#root .math-inline > .katex').length,
      display: document.querySelectorAll('#root .math-display .katex-display').length,
      errors: document.querySelectorAll('#root .katex-error').length,
    })]]

    it_browser("is typeset with GitHub's delimiters", function()
      local src = table.concat({
        "Inline $x^2$ and $`y_1`$.",
        "$$\n\\frac{a}{b}\n$$",
        "```math\n\\sqrt{2}\n```",
        "Display $$e^{i\\pi}$$ in a line.",
      }, "\n\n")
      assert.are.same({ inline = 2, display = 3, errors = 0 }, page(src, counts))
    end)

    it_browser("leaves prices and code alone", function()
      local src = "It costs $5 and $10.\n\n`$x$` and\n\n```\n$$y$$\n```"
      assert.are.same({ inline = 0, display = 0, errors = 0 }, page(src, counts))
    end)

    it_browser("shows a broken formula without breaking the page", function()
      local got = page("Before $\\frac{1$ after.\n\nNext paragraph.", counts .. ".errors + ',' + root.children.length")
      assert.are.equal("1,2", got)
    end)

    it_browser("has KaTeX's fonts loaded when the layout is reported", function()
      -- Fraktur is used nowhere else, so its font is not loaded yet
      local status = page(
        "",
        [[pageviewRender("$\\mathfrak{A}$").then(() =>
          [...document.fonts].filter((f) => f.family === "KaTeX_Fraktur").map((f) => f.status))]]
      )
      assert.is_true(vim.tbl_contains(status, "loaded"), vim.inspect(status))
    end)
  end)

  describe("mermaid", function()
    local flowchart = "```mermaid\ngraph TD\n  A[Start] --> B[End]\n```"

    it_browser("draws diagrams before the layout is reported", function()
      local got = page(
        flowchart .. "\n\nAfter.",
        [[({
          svgs: document.querySelectorAll('#root .pv-mermaid > svg').length,
          labels: [...document.querySelectorAll('#root .pv-mermaid .nodeLabel')].map((n) => n.textContent),
          code: document.querySelectorAll('#root pre').length,
        })]]
      )
      assert.are.same({ svgs = 1, labels = { "Start", "End" }, code = 0 }, got)
    end)

    it_browser("use the classic look, with curved edges and no shadows", function()
      local got = page(
        "```mermaid\nflowchart LR\n  A --> B\n  A --> C --> B\n```",
        [[(() => {
          const edges = [...document.querySelectorAll('#root .pv-mermaid .edgePaths path')];
          const shapes = [...document.querySelectorAll('#root .pv-mermaid .node rect, #root .pv-mermaid .node polygon')];
          return {
            edges: edges.length,
            curved: edges.filter((p) => /C/.test(p.getAttribute('d'))).length,
            shadows: shapes.filter((s) => /shadow/.test(getComputedStyle(s).filter + s.getAttribute('style'))).length,
          };
        })()]]
      )
      assert.are.same({ edges = 3, curved = 3, shadows = 0 }, got)
    end)

    it_browser("follow the theme", function()
      local label_color = "getComputedStyle(document.querySelector('#root .pv-mermaid .nodeLabel')).color"
      local dark = page(flowchart, label_color, { theme = "github-dark" })
      local light = page(flowchart, label_color, { theme = "github-light" })
      assert.are_not.equal(dark, light)
    end)

    it_browser("show a broken diagram's error in its place", function()
      local got = page(
        "```mermaid\ngraph TD\n  A --> \n  ((\n```\n\nAfter.",
        [[({
          error: document.querySelector('#root .pv-mermaid > pre.pv-mermaid-error').textContent.startsWith('Mermaid: '),
          after: document.querySelector('#root > p').textContent,
          stray: document.querySelectorAll('body > :not(#root):not(script)').length,
        })]]
      )
      assert.are.same({ error = true, after = "After.", stray = 0 }, got)
    end)
  end)

  describe("source lines", function()
    --- Source line ranges of the measured blocks.
    local function ranges(src)
      return page(
        "",
        ("pageviewRender(%s).then((m) => m.blocks.map((b) => [b[0], b[1]]))"):format(vim.json.encode(src))
      )
    end

    it_browser("are reported for every drawn block", function()
      local src = "# Title\n\nOne\ntwo\n\n- a\n- b\n\n> quote\n\n$$\nx\n$$\n\n```mermaid\ngraph TD\n  A --> B\n```"
      assert.are.same({
        { 0, 1 }, -- heading
        { 2, 4 }, -- paragraph
        { 5, 8 }, -- list (items in a tight list have no paragraphs)
        { 5, 6 },
        { 6, 8 },
        { 8, 9 }, -- quote
        { 8, 9 },
        { 10, 13 }, -- math
        { 14, 18 }, -- diagram
      }, ranges(src))
    end)

    it_browser("of code are reported one per line", function()
      local lines = {}
      for i = 1, 30 do
        lines[i] = ("local x%d = %d"):format(i, i)
      end
      local code = table.concat(lines, "\n")
      local blocks = page(
        "",
        ("pageviewRender(%s).then((m) => m.blocks)"):format(
          vim.json.encode("```lua\n" .. code .. "\n```\n\n    indented\n    code")
        )
      )
      assert.are.same({ 0, 32 }, { blocks[1][1], blocks[1][2] }) -- the box with its fences
      assert.are.same({ 1, 31 }, { blocks[2][1], blocks[2][2] }) -- the code lines
      assert.are.same({ 33, 35 }, { blocks[3][1], blocks[3][2] })
      assert.are.same({ 33, 35 }, { blocks[4][1], blocks[4][2] })
      -- code lines sit inside the box, at GitHub's 13.6px * 1.45 per line
      assert.is_true(blocks[2][3] > blocks[1][3] and blocks[2][4] < blocks[1][4])
      local per_line = (blocks[2][4] - blocks[2][3]) / 30
      assert.is_true(math.abs(per_line - 13.6 * 1.45) < 0.5, tostring(per_line))
    end)

    it_browser("skip what is not drawn", function()
      local src = "<details>\n<summary>S</summary>\n\nHidden text.\n\n</details>\n\nAfter."
      assert.are.same({ { 7, 8 } }, ranges(src))
    end)
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
