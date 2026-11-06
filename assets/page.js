// Called by pageview.nvim through the Chrome DevTools Protocol (Runtime.evaluate).
"use strict";

(() => {
  // Where page.html and vendor/ are. Absolute, because the document's
  // <base href> changes what relative URLs mean.
  const ASSETS = new URL(".", document.currentScript.src).href;

  // Code blocks are colored by highlight.js. Unknown languages stay plain.
  hljs.registerAliases(["viml", "vimscript"], { languageName: "vim" });
  function highlight(code, lang) {
    if (!lang || !hljs.getLanguage(lang)) return "";
    try {
      return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
    } catch (_) {
      return "";
    }
  }

  const md = window.markdownit({ html: true, linkify: true, highlight });

  // GitHub extensions
  md.use(window.markdownitTaskLists); // - [ ] / - [x], as disabled checkboxes
  md.use(window.markdownitEmoji, { shortcuts: {} }); // :tada:, but not :) as GitHub does not either

  // Footnotes, with GitHub's markup so github-markdown-css styles them: the
  // brackets around the number come from CSS, and no rule above the list.
  md.use(window.markdownitFootnote);
  const footnoteId = (tokens, idx) => {
    const { id, subId } = tokens[idx].meta;
    return String(id + 1) + (subId > 0 ? ":" + subId : "");
  };
  md.renderer.rules.footnote_ref = (tokens, idx) => {
    const n = String(tokens[idx].meta.id + 1);
    return `<sup><a href="#fn${n}" id="fnref${footnoteId(tokens, idx)}" data-footnote-ref>${n}</a></sup>`;
  };
  md.renderer.rules.footnote_block_open = () => '<section class="footnotes" data-footnotes>\n<ol>\n';
  md.renderer.rules.footnote_block_close = () => "</ol>\n</section>\n";
  md.renderer.rules.footnote_anchor = (tokens, idx) =>
    ` <a href="#fnref${footnoteId(tokens, idx)}" class="data-footnote-backref">↩︎</a>`;

  // Math as on GitHub: $…$ and $`…`$ inline, $$…$$ and ```math blocks, typeset
  // by KaTeX. $`…`$ goes first so the $…$ rule does not take its backticks.
  // GitHub has no equation numbers, so those rules are left out.
  for (const set of ["gitlab", "dollars"]) {
    const rules = texmath.rules[set];
    rules.block = rules.block.filter((r) => r.name !== "math_block_eqno");
    for (const r of rules.inline) {
      r.tmpl = `<span class="math ${r.displayMode ? "math-display" : "math-inline"}">$1</span>`;
    }
    for (const r of rules.block) r.tmpl = '<div class="math math-display">$1</div>';
  }
  md.use(texmath, {
    engine: katex,
    delimiters: ["gitlab", "dollars"],
    // HTML only: the MathML copy is for screen readers, and invisible here
    katexOptions: { output: "html", throwOnError: false },
  });
  // texmath renders blocks from a fixed template; add the token's attributes
  // (the source lines, below) to the template's div.
  for (const name of new Set(["gitlab", "dollars"].flatMap((set) => texmath.rules[set].block.map((r) => r.name)))) {
    const render = md.renderer.rules[name];
    md.renderer.rules[name] = (tokens, idx, options, env, self) =>
      render(tokens, idx, options, env, self).replace(/^<div/, () => "<div" + self.renderAttrs(tokens[idx]));
  }

  // Mermaid: a ```mermaid block keeps its source in a div, and becomes a
  // diagram after the page is sanitized (see renderDiagrams).
  const fence = md.renderer.rules.fence;
  md.renderer.rules.fence = (tokens, idx, options, env, self) => {
    const token = tokens[idx];
    if (token.info.trim().split(/\s+/)[0].toLowerCase() === "mermaid") {
      return `<div class="pv-mermaid"${self.renderAttrs(token)}>${md.utils.escapeHtml(token.content)}</div>\n`;
    }
    return fence(tokens, idx, options, env, self);
  };

  // Alerts: a top-level blockquote whose first line is only [!NOTE], [!TIP],
  // [!IMPORTANT], [!WARNING] or [!CAUTION] becomes GitHub's titled box.
  const ALERTS = {
    note: ["Note", "info"],
    tip: ["Tip", "light-bulb"],
    important: ["Important", "report"],
    warning: ["Warning", "alert"],
    caution: ["Caution", "stop"],
  };
  const ALERT_MARK = /^\[!(note|tip|important|warning|caution)\][ \t]*(?:\n|$)/i;
  md.core.ruler.after("block", "pageview_alerts", (state) => {
    const tokens = state.tokens;
    for (let i = 0; i < tokens.length; i++) {
      const open = tokens[i];
      const inline = tokens[i + 2];
      if (open.type !== "blockquote_open" || open.level !== 0) continue;
      if (tokens[i + 1].type !== "paragraph_open" || inline.type !== "inline") continue;
      const mark = ALERT_MARK.exec(inline.content);
      if (!mark) continue;
      let close = i + 1;
      for (let depth = 1; ; close++) {
        if (tokens[close].type === "blockquote_open") depth++;
        if (tokens[close].type === "blockquote_close" && --depth === 0) break;
      }
      const rest = inline.content.slice(mark[0].length);
      if (!rest.trim() && close === i + 4) continue; // nothing but the marker: a plain quote

      const kind = mark[1].toLowerCase();
      const [label, icon] = ALERTS[kind];
      open.tag = tokens[close].tag = "div";
      open.attrJoin("class", `markdown-alert markdown-alert-${kind}`);
      const title = new state.Token("html_block", "", 0);
      const svg = window.pageviewOcticons[icon].replace(
        "<svg ",
        `<svg class="octicon octicon-${icon} mr-2" aria-hidden="true" `,
      );
      title.content = `<p class="markdown-alert-title">${svg}${label}</p>\n`;
      if (rest.trim()) {
        inline.content = rest;
        tokens.splice(i + 1, 0, title);
      } else {
        tokens.splice(i + 1, 3, title); // the marker was the whole first paragraph
      }
    }
  });

  // Tag block elements with the source lines they come from (0-based, end
  // exclusive), so pageview can map source lines to rows and back. Code blocks
  // also get the range of their code lines, which render one per line.
  const countLines = (s) => (s ? s.split("\n").length - (s.endsWith("\n") ? 1 : 0) : 0);
  md.core.ruler.push("pageview_source_line", (state) => {
    for (const token of state.tokens) {
      if (token.map && token.nesting !== -1 && token.type !== "inline") {
        token.attrSet("data-source-line", String(token.map[0]));
        token.attrSet("data-source-end", String(token.map[1]));
        if (token.type === "fence" || token.type === "code_block") {
          const first = token.map[0] + (token.type === "fence" ? 1 : 0);
          token.attrSet("data-code-start", String(first));
          token.attrSet("data-code-end", String(first + countLines(token.content)));
        }
      }
    }
  });

  const root = document.getElementById("root");
  const userCss = document.getElementById("pv-user-css");

  // GitHub's font lists, with Korean fonts added before the emoji fonts.
  const CJK = '"Apple SD Gothic Neo", "Noto Sans CJK KR", "Noto Sans KR", "Malgun Gothic"';
  const BODY_FONT =
    '-apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif, ' +
    CJK +
    ', "Apple Color Emoji", "Segoe UI Emoji"';
  const CODE_FONT = 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace, ' + CJK;
  const fontList = (first, rest) => (first ? first + ", " + rest : rest);

  function setBase(href) {
    let base = document.querySelector("base");
    if (!href) {
      if (base) base.remove();
      return;
    }
    if (!base) {
      base = document.createElement("base");
      document.head.prepend(base);
    }
    base.href = href;
  }

  // Resolve when every image has loaded or failed, or after `ms`.
  function imagesLoaded(ms) {
    const pending = [...root.querySelectorAll("img")].filter((img) => !img.complete);
    if (pending.length === 0) return Promise.resolve();
    const all = Promise.all(
      pending.map(
        (img) =>
          new Promise((resolve) => {
            img.addEventListener("load", resolve, { once: true });
            img.addEventListener("error", resolve, { once: true });
          }),
      ),
    );
    return Promise.race([all, new Promise((resolve) => setTimeout(resolve, ms))]);
  }

  const nextFrame = () => new Promise((resolve) => requestAnimationFrame(() => resolve()));

  const timeout = (ms, what) =>
    new Promise((_, reject) => setTimeout(() => reject(new Error(`${what} took longer than ${ms / 1000}s`)), ms));

  // Mermaid is 5.5 MB, so it is loaded the first time a document needs it.
  let mermaidLoading = null;
  function loadMermaid() {
    mermaidLoading ||= new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = ASSETS + "vendor/mermaid/mermaid.min.js";
      script.onload = () => resolve(window.mermaid);
      script.onerror = () => {
        mermaidLoading = null;
        reject(new Error("could not load mermaid.min.js"));
      };
      document.head.append(script);
    });
    return mermaidLoading;
  }

  function showDiagramError(block, err) {
    const pre = document.createElement("pre");
    pre.className = "pv-mermaid-error";
    pre.textContent = "Mermaid: " + (err && err.message ? err.message : String(err));
    block.replaceChildren(pre);
  }

  // Draw every mermaid block, in the theme's colors. Resolves when all are
  // drawn, so the capture never shows a half-drawn page. A broken diagram
  // shows its error instead.
  let diagrams = 0;
  async function renderDiagrams() {
    const blocks = [...root.querySelectorAll("div.pv-mermaid")];
    if (blocks.length === 0) return;
    let mermaid;
    try {
      mermaid = await Promise.race([loadMermaid(), timeout(10000, "Loading mermaid")]);
    } catch (err) {
      blocks.forEach((block) => showDiagramError(block, err));
      return;
    }
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      suppressErrorRendering: true,
      theme: matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "default",
      // Mermaid 12 lays diagrams out with ELK in its "neo" look: right-angled
      // edges and shadows. GitHub draws the classic look with dagre's curves.
      look: "classic",
      layout: "dagre",
    });
    for (const block of blocks) {
      try {
        const id = `pv-mermaid-${++diagrams}`;
        const { svg } = await Promise.race([mermaid.render(id, block.textContent), timeout(10000, "The diagram")]);
        block.innerHTML = svg;
      } catch (err) {
        showDiagramError(block, err);
      }
    }
  }

  // GitHub's heading anchors (github-slugger): lower case, punctuation and
  // symbols removed except "-" and "_", spaces to "-", "-1", "-2"… for
  // repeats. Prefixed with "user-content-" as on GitHub, so a heading cannot
  // take the id of the page's own elements; links to "#slug" find it anyway.
  function slug(text) {
    return text.toLowerCase().replace(/[^\p{L}\p{M}\p{N}\p{Pc}\- ]/gu, "").replace(/ /g, "-");
  }
  function addHeadingIds() {
    const seen = new Map();
    for (const h of root.querySelectorAll("h1, h2, h3, h4, h5, h6")) {
      if (h.id) continue; // set in the document's own HTML
      const base = slug(h.textContent.trim());
      const n = seen.get(base) || 0;
      seen.set(base, n + 1);
      h.id = "user-content-" + (n ? `${base}-${n}` : base);
    }
  }

  /**
   * Render markdown into the page and report its geometry in CSS pixels.
   * @param {string} src
   * @param {{baseHref?: string, bodyFont?: string, codeFont?: string, css?: string,
   *          background?: "page"|"full"|"transparent"}} opts
   */
  window.pageviewRender = async (src, opts = {}) => {
    const html = document.documentElement;
    html.dataset.background = opts.background || "page";
    html.style.setProperty("--pv-body-font", fontList(opts.bodyFont, BODY_FONT));
    html.style.setProperty("--pv-code-font", fontList(opts.codeFont, CODE_FONT));
    userCss.textContent = opts.css || "";
    setBase(opts.baseHref);

    root.style.minHeight = "";
    root.innerHTML = DOMPurify.sanitize(md.render(src), { ADD_ATTR: ["target"] });
    addHeadingIds();

    await renderDiagrams();
    await imagesLoaded(5000);
    // also waits for fonts the new content needs (KaTeX's, for example)
    await document.fonts.ready;
    await nextFrame();

    // Fill around the article with its own background. With "page" the capture is
    // widened to whole cells, so a sliver outside the article is in the image too.
    const bg = opts.background === "transparent" ? "" : getComputedStyle(root).backgroundColor;
    html.style.background = bg;
    document.body.style.background = bg;

    const rect = root.getBoundingClientRect();
    return {
      width: document.documentElement.clientWidth,
      height: Math.max(rect.bottom + window.scrollY, 1),
      left: rect.left,
      articleWidth: rect.width,
      padLeft: parseFloat(getComputedStyle(root).paddingLeft) || 0,
      background: bg,
      blocks: measureBlocks(),
    };
  };

  // Where each tagged block is drawn: [first line, end line, top, bottom] in
  // document order, in CSS pixels. A code block is reported twice: the whole
  // box with its fences, then only its code lines, marked with a fifth item
  // (1) because they are evenly spaced.
  function measureBlocks() {
    const y = window.scrollY;
    const blocks = [];
    for (const el of root.querySelectorAll("[data-source-line]")) {
      if (!el.checkVisibility()) continue; // not drawn, as inside a closed <details>
      const r = el.getBoundingClientRect();
      const d = el.dataset;
      // fences put the attributes on <code>, indented code on <pre>
      const pre = d.codeStart !== undefined && el.closest("pre");
      if (pre) {
        const box = pre.getBoundingClientRect();
        blocks.push([Number(d.sourceLine), Number(d.sourceEnd), box.top + y, box.bottom + y]);
        if (Number(d.codeEnd) > Number(d.codeStart)) {
          const text = (pre.querySelector("code") || pre).getBoundingClientRect();
          blocks.push([Number(d.codeStart), Number(d.codeEnd), text.top + y, text.bottom + y, 1]);
        }
      } else {
        blocks.push([Number(d.sourceLine), Number(d.sourceEnd), r.top + y, r.bottom + y]);
      }
    }
    return blocks;
  }

  // Make the article exactly `px` tall so the last slice has a background.
  window.pageviewSetHeight = (px) => {
    root.style.minHeight = px + "px";
    return document.documentElement.scrollHeight;
  };
})();
