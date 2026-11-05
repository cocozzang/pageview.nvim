# Development tasks. Tools are looked up in PATH, then in a project-local
# luarocks tree (.luarocks) and Mason's bin folder.
export PATH := $(CURDIR)/.luarocks/bin:$(PATH)

MASON_BIN := $(HOME)/.local/share/nvim/mason/bin
STYLUA ?= $(or $(shell command -v stylua 2>/dev/null),$(MASON_BIN)/stylua)
LUALS ?= $(or $(shell command -v lua-language-server 2>/dev/null),$(MASON_BIN)/lua-language-server)

LUAROCKS_FLAGS := --lua-version=5.1 --tree=.luarocks

.PHONY: all deps fmt fmt-check lint test

all: fmt-check lint test

# Install busted and nlua into .luarocks (needs luarocks and LuaJIT headers).
deps:
	luarocks $(LUAROCKS_FLAGS) install busted
	luarocks $(LUAROCKS_FLAGS) install nlua

fmt:
	"$(STYLUA)" lua plugin tests

fmt-check:
	"$(STYLUA)" --check lua plugin tests

lint:
	VIMRUNTIME="$$(nvim --clean --headless -c 'lua io.write(vim.env.VIMRUNTIME)' -c 'qa!')" \
		"$(LUALS)" --check=lua --checklevel=Warning --configpath=$(CURDIR)/.luarc.json

# Tests use their own cache folder so they never touch the real one.
test:
	@if [ -d .luarocks ]; then eval "$$(luarocks $(LUAROCKS_FLAGS) path)"; fi; \
		XDG_CACHE_HOME=$(CURDIR)/.tests/cache busted
