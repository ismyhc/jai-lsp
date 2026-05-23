# Jai LSP for VSCode

Language server support for the **Jai** programming language. Provides hover with type info, go to definition, find all references, symbol outline, semantic-token highlighting, signature help, inlay hints, and real compiler diagnostics — all powered by the [jai-lsp](https://github.com/ismyhc/jai-lsp) server (written in Jai).

## Features

- **Hover** — type info for identifiers, with the resolved type pulled from the Jai compiler's own AST.
- **Go to Definition** (F12) — jump to symbol declarations across files.
- **Find All References** (⇧F12) — every place a name is used in the workspace.
- **Document Outline** (⌘⇧O) — top-level procs / structs / enums / constants.
- **Workspace Symbol Search** (⌘T) — fuzzy-search every top-level symbol.
- **Semantic-token highlighting** — keywords, strings, numbers, plus cross-file procs / structs / enums classified by the LSP.
- **Compiler diagnostics on save** — real errors from the Jai compiler with red squiggles. Requires `jai-lsp.entryFile` to be set.
- **Inlay hints** — `: Type` annotations after `x := ...` declarations.
- **Signature help** — popup with param info when typing `foo(`.
- **Folding ranges**, **completion**, **document symbols**, **go to type definition**.

## Requirements

- The **Jai compiler** itself (proprietary beta — not bundled). You need this to write Jai code anyway.
- macOS, Linux, and Windows.

## Setup

After installing the extension, point it at your Jai compiler:

```jsonc
// settings.json
{
    "jai-lsp.compilerPath": "/Users/you/Development/Tools/jai/bin/jai-macos"
}
```

For multi-file projects, also set the entry file so diagnostics work:

```jsonc
"jai-lsp.entryFile": "/Users/you/your-project/main.jai"
```

That's it — open a `.jai` file and the LSP attaches automatically.

## Settings

| Setting                       | Default     | What it does                                                                                                                       |
| ----------------------------- | ----------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `jai-lsp.serverPath`          | (bundled)   | Override the bundled `jai-lsp` binary with a custom build                                                                          |
| `jai-lsp.compilerPath`        | `""`        | Absolute path to your Jai compiler. Required for diagnostics and AST features                                                      |
| `jai-lsp.entryFile`           | `""`        | Project entry file. **Required for diagnostics** — without it, diagnostics are suppressed to avoid cascade errors from leaf-file compiles |
| `jai-lsp.inlayHints.enabled`  | `true`      | Whether the server emits `: Type` inlay hints                                                                                       |
| `jai-lsp.trace.server`        | `"off"`     | LSP message trace level. Set to `"verbose"` and check **Output → Jai LSP** if something's wrong                                    |

VSCode also has a per-language inlay-hint toggle:

```jsonc
"[jai]": { "editor.inlayHints.enabled": "off" }
```

## Troubleshooting

| Symptom                                    | Fix                                                                                              |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| "jai-lsp failed to start"                  | `jai-lsp.serverPath` doesn't resolve — leave it empty to use the bundled binary                  |
| Hover shows just back-ticked name          | You haven't saved the file yet — AST features refresh on save. Or `compilerPath` isn't set       |
| Diagnostics empty even with broken code    | Set `jai-lsp.entryFile` to your project's main file. Suppressed by design without it             |
| LSP attaches but features still don't work | Check **Output → Jai Language Server** for errors. Verify the bundled binary is executable      |

## Source

[github.com/ismyhc/jai-lsp](https://github.com/ismyhc/jai-lsp) — the LSP server (written in Jai), this VSCode extension, and integrations for Zed, Neovim, and Emacs all live in the same repository.

## License

MIT — see [LICENSE](https://github.com/ismyhc/jai-lsp/blob/main/LICENSE).
