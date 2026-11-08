# pageview.nvim

Neovim 창 하나에서 마크다운 버퍼를 원문과 브라우저로 렌더링한 페이지 사이에서 전환합니다.

[English](README.md) | 한국어

<!-- screenshot: Raw and Page side by side in Ghostty -->

페이지는 백그라운드의 headless Chromium 계열 브라우저가 그리고, 터미널에는 이미지로 표시됩니다. 그래서 비례 폰트,
실제 제목 크기, 여백까지 브라우저와 똑같이 보입니다. 스크롤은 평소처럼 `j`/`k`, `Ctrl-d`/`Ctrl-u`, `gg`/`G`로 합니다.

## 요구 사항

- Neovim 0.10 이상, `'termguicolors'` 켜기
- 유니코드 placeholder 방식의 kitty 그래픽 프로토콜을 지원하는 터미널: [kitty](https://sw.kovidgoyal.net/kitty/) 또는
  [Ghostty](https://ghostty.org/). tmux 안에서는 `set -g allow-passthrough on`이 필요합니다.
- Chromium 계열 브라우저: Google Chrome, Chromium, Brave, Microsoft Edge 중 하나. 백그라운드에서 headless로 실행되며,
  평소 쓰는 브라우저 창과는 따로 동작합니다.
- macOS 또는 Linux

## 설치

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "cocozzang/pageview.nvim",
  cmd = "Pageview",
  opts = {},
}
```

[rocks.nvim](https://github.com/nvim-neorocks/rocks.nvim):

```vim
:Rocks install pageview.nvim
```

`setup()`은 부르지 않아도 됩니다. 부르지 않으면 아래 기본값으로 동작합니다.

## 사용법

| 명령 | |
|---|---|
| `:Pageview` / `:Pageview toggle` | 현재 창을 원문과 페이지 사이에서 전환 |
| `:Pageview open` | 페이지 보기 |
| `:Pageview close` | 원문 버퍼로 돌아가기 |

기본 단축키는 없습니다. 예를 들면 이렇게 지정합니다.

```lua
vim.keymap.set("n", "<leader>um", "<cmd>Pageview toggle<cr>", { desc = "Toggle page view" })
```

전환해도 읽던 위치가 유지됩니다. 긴 문단이나 코드 블록 안에서도 커서가 있던 줄이 창의 같은 높이에 옵니다. 커서를
움직이지 않고 다시 전환하면 정확히 원래 자리로 돌아갑니다. 페이지는 열 때와 창 폭이 바뀔 때 렌더링하고, 바뀐 것이
없으면 캐시를 씁니다.

### 검색

페이지에서 `/`와 `?`는 마크다운 원문을 검색하고, 찾은 곳이 그려진 행으로 커서를 옮깁니다. `n`과 `N`은 다음, 이전
일치로 갑니다. 마지막 검색어, 검색 기록, 방향은 일반 검색과 같이 쓰기 때문에 원문 버퍼에서 시작한 검색을 페이지에서
이어 갈 수 있고 그 반대도 됩니다. `'ignorecase'`, `'smartcase'`, `'wrapscan'`이 적용됩니다. `'incsearch'`가 켜져
있으면 입력하는 동안 페이지가 따라오고, `<Esc>`를 누르면 원래 자리로 돌아갑니다. 일치 개수는 평소처럼 오른쪽에
나옵니다. 검색한 뒤 원문으로 전환하면 커서가 찾은 단어 위에 있습니다.

페이지는 이미지라서 찾은 단어 자체를 강조할 수는 없습니다. 대신 본문 왼쪽 여백에 막대를 그려서 위치를 표시합니다.
코드는 그 줄 옆에, 글은 그 문단(또는 목록 항목, 표의 행, 제목) 옆에 그립니다. `'hlsearch'`가 켜져 있으면
`:nohlsearch`로 사라지고, 원문으로 전환해도 사라집니다. 막대 색은 `Search`의 배경색이고, `PageviewMatch`의
전경색으로 바꿀 수 있습니다.

```lua
vim.api.nvim_set_hl(0, "PageviewMatch", { fg = "#f0883e" })
```

렌더링된 글자가 아니라 원문을 검색하기 때문에 마크다운 기호나 링크 주소도 검색됩니다.

### 링크

페이지에서 `gx`는 커서 행의 링크를 엽니다. 웹 링크는 시스템 기본 프로그램으로, 문서 옆의 파일은 Neovim으로 엽니다
(그림, PDF 같은 파일은 시스템 뷰어로). 한 행에 링크가 여러 개면 골라서 열고, 하나도 없으면 원문의 그 줄로
전환합니다.

문서 안 링크(목차, 각주)는 페이지 안에서 해당 제목이나 각주를 창 맨 위로 가져오고, `Ctrl-O`로 돌아옵니다. 제목에는
GitHub과 같은 앵커가 붙습니다(`#installation`, `#설치-방법`).

### 단축키

`n`, `N`, `gx`는 페이지 버퍼 안에서만 지정됩니다. `keymaps = false`로 두면 지정하지 않으니,
`require("pageview").search_next()`, `search_next(true)`, `open_link()`를 직접 지정하면 됩니다(예를 들어
`FileType pageview` 자동 명령에서). `/`와 `?`는 항상 원문을 검색합니다.

### 상태 표시줄

`require("pageview").status()`는 `"PAGE"`, `"RAW"`(페이지로 볼 수 있는 버퍼), `""` 중 하나를 돌려줍니다.

```lua
-- lualine
sections = { lualine_x = { function() return require("pageview").status() end } }
```

## 지원하는 마크다운

- CommonMark와 GitHub의 표, 취소선, 주소 자동 링크
- 체크박스 목록 (`- [ ]`, `- [x]`)
- 각주 (`[^1]`)
- 알림 상자 (`> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`)
- 이모지 단축 코드 (`:tada:`)
- [KaTeX](https://katex.org/) 수식: 인라인은 `$…$`, `` $`…`$ ``, 블록은 `$$…$$`, ` ```math `
- ` ```mermaid ` 블록의 [Mermaid](https://mermaid.js.org/) 다이어그램. 테마 색으로 그리고, 잘못된 다이어그램은 그
  자리에 오류를 보여 줍니다.
- [highlight.js](https://highlightjs.org/)로 색칠한 코드 블록 (기본 언어 묶음과 Vim script)
- 문서 안 HTML (스크립트와 이벤트 속성은 지움)
- 파일 폴더 기준의 상대 경로 그림과 링크

`tests/fixtures/showcase.md`에 전부 모아 두었습니다.

## 설정

```lua
require("pageview").setup({
  theme = nil, -- "github-dark" | "github-light"; nil이면 'background'를 따름
  background = "page", -- "page": 본문 폭만 | "full": 창 전체 | "transparent": 투명
  zoom = 1, -- 터미널 글꼴 크기에서 정한 배율에 곱함
  font = {
    body = nil, -- CSS font-family 목록; nil이면 GitHub 기본
    code = nil, -- nil이면 알아낼 수 있을 때 터미널 글꼴 (Ghostty)
  },
  css = nil, -- 테마 뒤에 적용할 CSS 파일 경로
  browser = nil, -- 브라우저 경로; nil이면 흔한 위치에서 찾음
  browser_args = {}, -- 브라우저 추가 인자
  browser_idle_timeout = 600, -- 이 시간(초) 동안 안 쓰면 브라우저를 끔; 0이면 끄지 않음
  filetypes = { "markdown" },
  cache_max_size = 200 * 1024 * 1024, -- 디스크에 보관할 렌더링 이미지 용량(바이트)
  keymaps = true, -- 페이지 버퍼에 n, N, gx 지정
})
```

뭔가 안 보이면 `:checkhealth pageview`를 실행해 보세요.

## 제약

- 페이지를 보여 줄 수 있는 터미널은 kitty와 Ghostty뿐입니다. 다른 터미널에서는 `:checkhealth pageview`를 안내하는
  오류가 납니다.
- 페이지는 그림이라서 글자를 선택하거나 복사할 수 없고, 검색도 단어가 아니라 줄이나 문단을 표시합니다. 그럴 때는
  원문으로 전환하세요.
- 페이지는 읽기 전용입니다. 편집은 원문에서 하고, 바뀐 내용은 다음에 페이지를 열 때 반영됩니다.
- Neovim과 브라우저가 같은 컴퓨터에서 실행되어야 합니다. SSH 원격 접속은 지원하지 않습니다.

## 동작 방식

1. 버퍼 내용을 [markdown-it](https://github.com/markdown-it/markdown-it),
   [DOMPurify](https://github.com/cure53/DOMPurify),
   [github-markdown-css](https://github.com/sindresorhus/github-markdown-css), highlight.js, KaTeX, Mermaid가 든
   페이지 틀에 넣습니다. 이 페이지는 `--remote-debugging-pipe`로 띄운 headless 브라우저에서 열리고, Chrome
   DevTools Protocol로 조종합니다.
2. 페이지를 창 폭에 맞춰 배치합니다. 터미널 칸 하나가 정해진 CSS 픽셀 수에 대응합니다.
3. 화면에 보이는 행 근처의 페이지 조각을 PNG로 찍어서 kitty 그래픽 프로토콜로 터미널에 보냅니다. 페이지 버퍼의 한
   줄이 이미지의 터미널 한 행입니다.
4. 스크롤해서 멀어진 조각은 터미널 메모리에서 다시 지웁니다.

## 개발

```sh
make deps   # busted와 nlua를 .luarocks에 설치 (luarocks와 LuaJIT 헤더 필요)
make test   # 끝까지 확인하는 테스트에 Chromium 계열 브라우저 필요
make lint   # lua-language-server
make fmt    # stylua
```

넣어 둔 라이브러리의 버전은 `assets/vendor/VERSIONS`에 고정되어 있고, `scripts/update-vendor.sh`로 갱신합니다.

## 라이선스

MIT. 넣어 둔 라이브러리는 각자의 라이선스를 따르며, 원문을 `assets/vendor/` 안에 함께 두었습니다:
markdown-it (MIT), github-markdown-css (MIT), DOMPurify (Apache-2.0 또는 MPL-2.0), highlight.js (BSD-3-Clause),
markdown-it-task-lists (ISC), markdown-it-footnote (MIT), markdown-it-emoji (MIT), Octicons (MIT), KaTeX (MIT),
markdown-it-texmath (MIT), Mermaid (MIT).
