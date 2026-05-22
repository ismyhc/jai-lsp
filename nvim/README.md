# jai-lsp.nvim

Neovim plugin for the Jai language server.

**Requires Neovim 0.8+** (built-in LSP). Tree-sitter highlighting is
optional and lights up automatically when [`nvim-treesitter`](https://github.com/nvim-treesitter/nvim-treesitter)
is installed.

## Install (LazyVim / lazy.nvim)

Drop this into `~/.config/nvim/lua/plugins/jai.lua`:

```lua
return {
    {
        "ismyhc/jai-lsp",
        ft = "jai",
        opts = {
            server_path   = "jai-lsp",                                    -- or absolute path
            compiler_path = "/Users/you/Development/Tools/jai/bin/jai-macos",
            entry_file    = nil,                                          -- set for diagnostics
            inlay_hints   = true,
        },
        dependencies = {
            -- Only needed for the tree-sitter grammar. Without it the LSP
            -- still works, you just get less syntax highlighting.
            "nvim-treesitter/nvim-treesitter",
        },
    },
}
```

After Lazy installs it, run once to fetch the tree-sitter grammar:

```vim
:TSInstall jai
```

Open any `.jai` file. The LSP attaches automatically; standard built-in
LSP commands work (`gd`, `K`, `gr`, `<leader>ca`, etc., depending on your
LazyVim keymap).

## Install (packer.nvim / vim-plug / manual)

```lua
-- packer
use {
    "ismyhc/jai-lsp",
    requires = { "nvim-treesitter/nvim-treesitter" },
    config = function()
        require("jai-lsp").setup({
            compiler_path = "/abs/path/to/jai-macos",
        })
    end,
}
```

```vim
" vim-plug
Plug 'nvim-treesitter/nvim-treesitter'
Plug 'ismyhc/jai-lsp'
" then in your init.lua:
lua require("jai-lsp").setup({ compiler_path = "/abs/path/to/jai-macos" })
```

## Configuration

`require('jai-lsp').setup({...})` accepts:

| Key             | Default      | What                                                                                                                   |
| --------------- | ------------ | ---------------------------------------------------------------------------------------------------------------------- |
| `server_path`   | `"jai-lsp"`  | Path to the jai-lsp binary. PATH is searched if unqualified                                                            |
| `compiler_path` | `nil`        | Absolute path to the Jai compiler. Forwarded as `JAI_COMPILER` env var. **Required for diagnostics + AST features**    |
| `entry_file`    | `nil`        | Project entry file. Forwarded as `JAI_LSP_ENTRY_FILE`. **Required for diagnostics**; suppressed without it             |
| `inlay_hints`   | `true`       | Whether to emit `: Type` inferred-type annotations. Forwarded as `JAI_LSP_INLAY_HINTS`                                 |
| `parser_config` | `nil`        | Override the default tree-sitter parser-config table. Useful for pointing at your own fork of `tree-sitter-jai`        |

All settings are forwarded to the spawned LSP process via env vars (the
server reads them at startup). Changing `entry_file` after the LSP has
started requires a restart (`:LspRestart`).

## Status

- **LSP wiring**: functional. Hover (`K`), Go to Definition (`gd`),
  Find References (`gr`), Completion (`<C-x><C-o>` or any completion
  plugin you have), Code Action, Rename are all standard `vim.lsp`
  commands the LSP server answers.
- **Tree-sitter highlighting**: works via the upstream
  `constantitus/tree-sitter-jai` grammar.
- **Signature help**: works via `vim.lsp.buf.signature_help` (often
  bound to `<C-k>` in LazyVim). Some completion plugins (cmp, blink) auto-trigger it on `(`.
- **Inlay hints**: enable in your config with
  `vim.lsp.inlay_hint.enable(true)`. LazyVim has a toggle.

> **Status: lightly tested.** The plugin loads cleanly and the LSP is the
> same binary used in VSCode/Zed/Emacs (which are exercised in our smoke
> tests), so the protocol side is solid. The Neovim integration glue has
> not been heavily used by the project author — PRs welcome for nicer
> defaults, recommended keymaps, or LazyVim "extras" packaging.
