# tree-sitter-jai

Tree-sitter grammar for the **Jai** programming language. Originally written
by [constantitus](https://github.com/constantitus/tree-sitter-jai); vendored
into this repo so the jai-lsp project owns its full toolchain. See `LICENSE`
for original attribution.

## What's here

```
grammar.js                  # the grammar definition
src/parser.c                # generated parser (regenerate with `tree-sitter generate`)
src/scanner.c               # external scanner (heredocs, nested block comments)
queries/highlights.scm      # syntax highlighting queries
queries/indents.scm         # indentation queries
queries/context.scm         # context queries
bindings/                   # Node, Rust, Python, Go, Swift bindings
test/corpus/                # parser tests
```

## Editor integration

Tree-sitter grammars are universal — any editor with tree-sitter support
can consume this. The recipes below assume you've forked / hosted this
repo somewhere accessible.

### Zed

The jai-lsp Zed extension (in `../zed-extension/`) references this grammar
via the `[grammars.jai]` block in `extension.toml`. Currently points at the
upstream `constantitus/tree-sitter-jai` since Zed expects a Git URL; once
this vendored copy is hosted publicly, swap that URL.

### Neovim (nvim-treesitter)

```lua
require('nvim-treesitter.parsers').get_parser_configs().jai = {
    install_info = {
        url      = "https://github.com/<your-account>/jai-lsp",
        files    = { "tree-sitter-jai/src/parser.c", "tree-sitter-jai/src/scanner.c" },
        branch   = "main",
        location = "tree-sitter-jai",
    },
    filetype = "jai",
}
require('nvim-treesitter.configs').setup { ensure_installed = { "jai" } }
```

Then `:TSInstall jai`. Pair with `nvim-lspconfig` pointing at the `jai-lsp`
binary for full IDE features.

### Emacs (Emacs 29+ built-in tree-sitter)

```elisp
(setq treesit-language-source-alist
      '((jai "https://github.com/<your-account>/jai-lsp" "main" "tree-sitter-jai/src")))
(treesit-install-language-grammar 'jai)
```

Define a `jai-ts-mode` (or use `treesit-auto`) and wire `eglot` against
`jai-lsp` for LSP features.

### Helix

In `languages.toml`:

```toml
[[language]]
name             = "jai"
scope            = "source.jai"
file-types       = ["jai"]
language-servers = ["jai-lsp"]

[[grammar]]
name   = "jai"
source = { git = "https://github.com/<your-account>/jai-lsp",
           rev = "<sha>", subpath = "tree-sitter-jai" }

[language-server.jai-lsp]
command = "jai-lsp"
```

Then `helix --grammar fetch && helix --grammar build`.

## Regenerating the parser

After editing `grammar.js`:

```sh
tree-sitter generate          # rewrites src/parser.c, src/grammar.json, etc.
tree-sitter test              # runs test/corpus/
tree-sitter parse path/to/foo.jai   # parse a single file
```

`src/parser.c` / `src/grammar.json` are checked in so consumers don't need
the tree-sitter CLI just to build a parser.

## Status

Parses every file in this repo's `src/` cleanly. Edge cases that still
produce errors include `#asm { ... }` blocks, some polymorphic-struct
argument forms, and the most exotic `#string,\\%` herestring modifier.
