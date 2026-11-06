#!/usr/bin/env sh
# Download the browser-side libraries listed in assets/vendor/VERSIONS.
# Files come from the npm registry through jsDelivr, pinned to exact versions.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
vendor="$root/assets/vendor"
cdn="https://cdn.jsdelivr.net/npm"

fetch() { # <package> <version> <remote path> <local path>
  mkdir -p "$(dirname "$vendor/$4")"
  curl -fsSL "$cdn/$1@$2/$3" -o "$vendor/$4"
  echo "  $4"
}

grep -v '^#' "$vendor/VERSIONS" | while read -r name version; do
  [ -n "$name" ] || continue
  echo "$name $version"
  case "$name" in
  markdown-it)
    fetch "$name" "$version" dist/browser/markdown-it.umd.min.js markdown-it/markdown-it.min.js
    fetch "$name" "$version" LICENSE markdown-it/LICENSE
    ;;
  github-markdown-css)
    fetch "$name" "$version" github-markdown.css github-markdown-css/github-markdown.css
    fetch "$name" "$version" license github-markdown-css/LICENSE
    ;;
  dompurify)
    fetch "$name" "$version" dist/purify.min.js dompurify/purify.min.js
    fetch "$name" "$version" LICENSE dompurify/LICENSE
    ;;
  @highlightjs/cdn-assets)
    # the common languages, plus Vim script
    fetch "$name" "$version" highlight.min.js highlight.js/highlight.min.js
    fetch "$name" "$version" languages/vim.min.js highlight.js/vim.min.js
    fetch "$name" "$version" styles/github.min.css highlight.js/github.min.css
    fetch "$name" "$version" styles/github-dark.min.css highlight.js/github-dark.min.css
    fetch "$name" "$version" LICENSE highlight.js/LICENSE
    ;;
  *)
    echo "unknown package: $name" >&2
    exit 1
    ;;
  esac
done
