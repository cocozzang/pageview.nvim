// Called by pageview.nvim through the Chrome DevTools Protocol (Runtime.evaluate).
"use strict";

(() => {
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

  // Tag block elements with the source line they start at (0-based).
  // Used to keep the reading position when switching between raw and page.
  md.core.ruler.push("pageview_source_line", (state) => {
    for (const token of state.tokens) {
      if (token.map && token.nesting !== -1 && token.type !== "inline") {
        token.attrSet("data-source-line", String(token.map[0]));
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

    await imagesLoaded(5000);
    await document.fonts.ready;
    await nextFrame();

    // Fill around the article with its own background. With "page" the capture is
    // widened to whole cells, so a sliver outside the article is in the image too.
    const bg = opts.background === "transparent" ? "" : getComputedStyle(root).backgroundColor;
    html.style.background = bg;
    document.body.style.background = bg;

    const rect = root.getBoundingClientRect();
    const lines = [];
    for (const el of root.querySelectorAll("[data-source-line]")) {
      lines.push([Number(el.dataset.sourceLine), el.getBoundingClientRect().top + window.scrollY]);
    }
    return {
      width: document.documentElement.clientWidth,
      height: Math.max(rect.bottom + window.scrollY, 1),
      left: rect.left,
      articleWidth: rect.width,
      lines,
    };
  };

  // Make the article exactly `px` tall so the last slice has a background.
  window.pageviewSetHeight = (px) => {
    root.style.minHeight = px + "px";
    return document.documentElement.scrollHeight;
  };
})();
