# pageview.nvim showcase

Every Markdown feature pageview renders, in one document. Open it side by side with GitHub or another previewer
to compare.

## Text

A paragraph with **bold**, *italic*, ~~strikethrough~~, `inline code` and a [link](https://github.com).
A bare URL becomes a link too: https://neovim.io

한글 문단도 섞어 둔다. 다람쥐 헌 쳇바퀴에 타고파.

## Headings

### Third level

#### Fourth level

##### Fifth level

###### Sixth level

## Lists

- One
- Two
  - Nested
  - Nested again
- Three

1. First
2. Second
3. Third

Task list:

- [x] Done
- [ ] Not yet
  - [ ] Nested

## Footnotes

A sentence with a footnote[^1] and another one[^note].

[^1]: The first footnote.
[^note]: A named footnote. Footnotes are listed at the end of the document.

## Quote

> A blockquote with **bold** text.
>
> > And a nested one.

## Table

| Left | Center | Right |
|:-----|:------:|------:|
| a    | b      | c     |
| long cell | `code` | 42 |

## Code

```lua
-- Lua
local function greet(name)
  return ("hello %s"):format(name)
end
```

```javascript
// JavaScript
const sum = (xs) => xs.reduce((a, b) => a + b, 0);
console.log(sum([1, 2, 3]));
```

```bash
# Shell
for f in *.md; do
  echo "$f"
done
```

```vim
" Vim script
nnoremap <leader>um <cmd>Pageview toggle<cr>
set termguicolors
```

```
A code block without a language.
```

## Image

A relative path, resolved against this file's folder:

![A blue dot](dot.svg)

## HTML

<details>
<summary>Click to expand</summary>

Inline HTML is kept. Scripts are removed.

</details>

---

The end.
