# jai-lsp

A Language Server Protocol (LSP) implementation for the **Jai** programming
language, **written in Jai**. Speaks LSP over stdio so any LSP-capable
editor can drive it. Ships with a VSCode extension and a Zed extension.

## Features

| Capability | What it does | Powered by |
|---|---|---|
| **Hover** | Mouse-over an identifier → type popup, e.g. `add :: (s64, s64) -> s64` | Compiler AST |
| **Goto Definition** (F12) | Jump to where a symbol is declared | Workspace symbol index |
| **Goto Type Definition** | Jump to the struct/enum a variable's type points to | Compiler AST |
| **Find All References** (⇧F12) | Every place a name is used, across the workspace | Lexer scan of all `.jai` files |
| **Document Outline** (⌘⇧O) | Top-level procs/structs/enums/constants in this file | Lexer |
| **Workspace Symbol Search** (⌘T) | Fuzzy-search every top-level symbol in the project | Lexer |
| **Semantic Tokens** | Coloring for keywords/strings/numbers + this-file's decls (functions, structs, enums) | Lexer + AST |
| **Diagnostics on Save** | Real compile errors with red squiggles, e.g. `Undeclared identifier 'foo'` | Subprocess `jai` with `output_type=NO_OUTPUT` |
| **Folding Ranges** | Collapse `{...}` blocks | Lexer |
| **Completion** | Workspace symbols + Jai keywords (context-free) | Workspace index |
| **Signature Help** | Type `foo(` → popup with `(a: int, b: int) -> int`, active-param highlight | Lexer + source extraction |
| **Inlay Hints** | `: Type` ghost annotations after `x := ...` declarations | Compiler AST |

Implementation notes:

- Workspace scanned once on `initialized`, then kept in sync via
  `didOpen` / `didChange` / `didClose` / `workspace/didChangeWatchedFiles`.
- Compiler-AST features (hover with types, goto type definition, inlay hints)
  refresh on **save** by spawning the Jai compiler in type-check-only mode.
- The check is **async**: save returns immediately; results arrive when the
  subprocess finishes. Handlers that need AST data drain the pending check
  if you trigger them right after saving.
- Negotiates `positionEncoding: utf-8` when the client supports it; falls
  back to UTF-16 (the LSP default).

## Quick start

```sh
# 1. Build the server
jai build.jai                          # produces ./jai-lsp

# 2. (Optional) sanity check
JAI_COMPILER=/abs/path/to/jai bun test/smoke.ts
```

### VSCode

```sh
cd vscode-extension
npm install
npm run compile
```

Then open the `vscode-extension/` folder in VSCode and press <kbd>F5</kbd> —
an Extension Development Host window launches with the extension active.
Open any `.jai` file or folder in it.

Required settings (in the dev-host window, `Cmd+,` → search "jai-lsp"):

```jsonc
{
    // Path to the binary you just built:
    "jai-lsp.serverPath":   "/abs/path/to/jai-lsp/jai-lsp",
    // Path to the Jai compiler — needed for diagnostics & AST features:
    "jai-lsp.compilerPath": "/abs/path/to/jai/bin/jai-macos"
}
```

Optional:

```jsonc
{
    // Project's main file — fixes cross-module hovers in multi-file projects.
    // Unset = compile per-file (sees only the open file's symbols).
    "jai-lsp.entryFile":         "/abs/path/to/project/main.jai",

    // Hide the `: Type` ghost annotations:
    "jai-lsp.inlayHints.enabled": false
}
```

### Neovim / Emacs / Helix

The server speaks plain LSP — point any LSP client at the `jai-lsp` binary
and you're set. For syntax highlighting, the `tree-sitter-jai/` directory
ships the grammar; see its README for editor-specific install snippets
(nvim-treesitter, Emacs 29+ tree-sitter, Helix `languages.toml`).

### Zed

```sh
# 1. Build the binary as above.
# 2. Install the bundled extension:
cd zed-extension
# Then in Zed: Cmd+Shift+P → "zed: install dev extension" → pick this folder
```

Zed picks up `.jai` files via the extension. Configure the compiler path
in Zed settings (`Cmd+,`):

```json
{
    "lsp": {
        "jai-lsp": {
            "binary": {
                "path": "/abs/path/to/jai-lsp/jai-lsp"
            },
            "settings": {
                "jai-lsp": {
                    "compilerPath": "/abs/path/to/jai/bin/jai-macos",
                    "entryFile":    ""
                }
            }
        }
    }
}
```

## Settings reference

| Key | Default | What |
|---|---|---|
| `jai-lsp.serverPath`         | `"jai-lsp"`        | Server binary path. PATH lookup if bare name |
| `jai-lsp.compilerPath`       | `""`               | Absolute path to Jai compiler. Shell aliases don't survive subprocess spawn — set this explicitly |
| `jai-lsp.entryFile`          | `""`               | Project entry file (the one with `main :: ()`). Set this for multi-file projects so all imports get type-checked. Unset = compile per-file |
| `jai-lsp.inlayHints.enabled` | `true`             | Whether to emit `: Type` annotations after `:=` |
| `jai-lsp.trace.server`       | `"off"`            | LSP message trace level (VSCode) |

Settings reach the server through environment variables the extension sets
(`JAI_COMPILER`, `JAI_LSP_ENTRY_FILE`, `JAI_LSP_INLAY_HINTS`). If you're
running jai-lsp from a different editor, set those env vars yourself.

## Project layout

```
build.jai                  # `jai build.jai` → ./jai-lsp
src/
  main.jai                 # entry point: install logger, read/dispatch loop, tick async checks
  rpc.jai                  # Content-Length framing, poll_stdin
  log.jai                  # stderr-only logger
  protocol.jai             # LSP type structs
  documents.jai            # open-document store, position math (utf-8 / utf-16)
  analysis.jai             # Jai_Lexer wrapper: semantic tokens, decls, folds, sigs, refs
  workspace.jai            # workspace-wide symbol index, scan, refresh
  checker.jai              # type-check subprocess: metaprogram, AST sidecar, Pending_Check
  server.jai               # state, dispatch table, all request handlers
test/
  smoke.ts                 # bun-driven LSP smoke tests (13 sessions, ~100 checks)
vscode-extension/          # ~50-line TS shim using vscode-languageclient
zed-extension/             # Zed extension (registers jai language)
tree-sitter-jai/           # Vendored tree-sitter grammar — originally constantitus/tree-sitter-jai (MIT-0), see Credits
package.jai                # `jai package.jai` → builds binary + drops into extension bin/ dirs
```

## Architecture

### The wire

LSP is JSON-RPC 2.0 with `Content-Length` framing over stdio. **stdout is
the protocol channel** — never `print` to it. All logging goes to stderr
via `stderr_logger` in `log.jai`. The default `context.logger` is replaced
at startup so even stdlib log calls are safely routed.

### The read loop

`main.jai`:

1. `poll_stdin` with a timeout. When a check is in flight, timeout is 25ms
   so the subprocess polling can fire; otherwise blocks indefinitely.
2. If stdin is ready, read a framed message and dispatch via
   `handle_message`.
3. `tick_pending_check` — if a type-check subprocess is running, drain
   available output. When it finishes, parse stderr → diagnostics,
   load the AST sidecar, publish.
4. `reset_temporary_storage` — all per-message scratch (parsed JSON
   tree, response builders) is on temp.

### Memory model

- **Per message:** parse, build response, reset temp at end of loop.
  Allocate with `temp` allocator explicitly via `,, allocator=temp` when
  the parser would otherwise use heap.
- **Long-lived:** documents (`Document_Store`), workspace symbols
  (`Workspace`), AST index (`Ast_Index`) live on `context.allocator`
  (heap). Explicit `free` when entries are removed.

### Three indices

| Index | Built when | Powers |
|---|---|---|
| `Document_Store` | didOpen/didChange/didClose | hover (fallback), text reads |
| `Workspace.by_name` | initialize scan + watcher events | definition, references, completion, workspace symbol |
| `Ast_Index` | each check completes | hover with types, goto type def, inlay hints |

### The check pipeline

`checker.jai` ships a tiny build metaprogram (embedded as a string,
written to `/tmp/jai-lsp-check.jai`). On save, `start_check` spawns
`jai <metaprogram> - <entry_file> <ast_sidecar_path>` via
`Process.create_process` in capture mode. The metaprogram:

1. Sets `output_type = NO_OUTPUT` — type-check only.
2. Calls `compiler_begin_intercept` and consumes `Message_Typechecked`.
3. Writes JSONL to the sidecar: one line per declaration with
   `{name, kind, type, file, line, col}`.
4. The compiler emits errors to stderr in the standard
   `path:line,col: Error: message` format that jai-lsp parses.

Back in the main loop, `tick_pending_check` polls the subprocess each
iteration (`read_from_process` + `get_process_result`, both with
`timeout_ms=0`). When finished: parse stderr → diagnostics; reload AST
sidecar; publish `textDocument/publishDiagnostics`.

## Development

### Add a new handler

1. **Type:** add a struct in `src/protocol.jai` if the response shape isn't
   already there. LSP enum values that the spec expects as numbers should
   be `int` fields, not enum-typed (jaison would serialize enum names as
   strings).
2. **Capability:** flip the relevant `XxxProvider` flag in
   `Server_Capabilities`.
3. **Dispatch:** add a `case "textDocument/foo"` line in `handle_message`
   (`server.jai`, near the top).
4. **Handler:** write `handle_foo(server, id, envelope_obj)`. Helpers:
   - `jv_object` / `jv_string` / `jv_int` / `jv_array` for walking JSON_Value params
   - `word_at_position` for "identifier under cursor"
   - `send_result(id, payload)` to reply
   - `json_write_string(value, indent_char="")` to serialize
5. **Test:** add a smoke-test session in `test/smoke.ts`. Use the existing
   `runSession` helper. If your feature depends on AST data, gate the
   session on `process.env.JAI_COMPILER` so it skips when the compiler
   isn't available.

### Run the test suite

```sh
bun test/smoke.ts                              # 12 sessions, no compiler needed
JAI_COMPILER=/abs/path/to/jai bun test/smoke.ts   # 13 sessions including AST features
```

Each session spawns a fresh `./jai-lsp`, drives it via stdio, and asserts
on the framed responses + notifications.

### Compile

```sh
jai build.jai
```

Drives compilation via the `build.jai` metaprogram so the output binary
name (`jai-lsp`) and path are fixed regardless of how the compiler is
invoked.

## Known limits

| | |
|---|---|
| **Single-threaded.** | Only one check runs at a time; new ones cancel the old. Workspace scan on initialize blocks the loop briefly. |
| **No scope analysis.** | Find-all-references returns same-named decls across scopes — local shadowing isn't disambiguated. Real fix needs the parser. |
| **Type names are canonical.** | `int` shows as `s64`, `float` as `float32` — that's the resolved type, not source spelling. |
| **AST refreshes on save only.** | Live edits between saves see the previous save's type info. Live-on-keystroke would need debounced incremental checks. |
| **Whole-file synced.** | `textDocumentSync = 1` (full). Incremental sync is a future optimization. |
| **Jai_Lexer `#string,<modifier>` bug.** | Files containing `#string,\%` crash the bundled lexer; jai-lsp text-scans for that pattern and skips analysis on those files. Remove the guard in `analysis.jai` when upstream is fixed. |

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| **"jai-lsp failed to start"** | `serverPath` doesn't resolve. Set to an absolute path |
| **Diagnostics empty even with broken code** | `compilerPath` unset or wrong; check `Output → Jai Language Server` for the `Couldn't launch process` line |
| **Hover shows just the back-ticked name** | AST index empty for this symbol — either you haven't saved yet, or the symbol lives in a module the entry-file compile doesn't pull in. Set `jai-lsp.entryFile` to the right entry point. |
| **"crashed N times in M minutes"** | Server-side bug. Reproduce with `bun test/smoke.ts` (sometimes spots it) or run the binary manually with the failing input on stdin. |

All server diagnostics go to **stderr**, which the VSCode extension surfaces
in `Output → Jai Language Server`. Set `jai-lsp.trace.server: "verbose"` for
full wire-level traces.

## Credits

The vendored tree-sitter grammar in [`tree-sitter-jai/`](tree-sitter-jai/)
was originally written by **[constantitus](https://github.com/constantitus/tree-sitter-jai)**
and is included here under its **MIT-0** license. Attribution is preserved in
`tree-sitter-jai/LICENSE` and at the top of `tree-sitter-jai/grammar.js`.
We may eventually write our own grammar from scratch; until then, full credit
for the parser implementation goes to constantitus and the contributors
acknowledged in their grammar.js header (tree-sitter-odin, tree-sitter-go,
tree-sitter-tlaplus, tree-sitter-php).

## License

See LICENSE (not yet added).
