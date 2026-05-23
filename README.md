<img src="vscode-extension/icon.png" alt="jai-lsp" width="80" />

# jai-lsp

A Language Server Protocol implementation for the **Jai** programming language, **written in Jai**. Speaks LSP over stdio so any LSP-capable editor can drive it.

**Ships with integrations for VSCode, Zed, Emacs, and Neovim.**

## Features

Hover with types · Go to definition / type definition · Find all references · Document outline · Workspace symbol search (⌘T) · Code completion · Signature help · Inlay hints · Semantic-token highlighting · Folding ranges · Real compiler diagnostics on save.

## Install

Each editor has its own setup — pick yours:

| Editor   | Where                                                         |
| -------- | ------------------------------------------------------------- |
| VSCode   | Install the `.vsix` from the [latest release](https://github.com/ismyhc/jai-lsp/releases) |
| Zed      | [`zed-extension/README.md`](zed-extension/README.md)          |
| Neovim   | [`nvim/README.md`](nvim/README.md)                            |
| Emacs    | [`emacs/README.md`](emacs/README.md)                          |

Every editor expects two settings:

- `jai-lsp.compilerPath` — absolute path to your Jai compiler binary
- `jai-lsp.entryFile` — your project's main file (required for diagnostics)

## Build from source

You need the Jai compiler installed.

```sh
jai build.jai          # produces ./jai-lsp
```

For per-platform extension binaries, see [`RELEASING.md`](RELEASING.md).

## Credits

The vendored tree-sitter grammar in [`tree-sitter-jai/`](tree-sitter-jai/) was originally written by [constantitus](https://github.com/constantitus/tree-sitter-jai) and is included under its **MIT-0** license.

## License

[MIT](LICENSE) © Jacob Davis.
