# jai-lsp

Language Server Protocol implementation for the **Jai** programming language,
written in Jai. Speaks LSP over stdio, so any LSP-capable editor can drive it.

What it does today (M0–M4): document sync, hover, semantic tokens (keywords,
strings, numbers, identifiers), lex-level diagnostics, document symbol
outline, workspace-wide go-to-definition, and (context-free) completion of
workspace symbols + Jai keywords.

---

## Build

```sh
jai build.jai          # produces ./jai-lsp at the project root
```

Optional smoke test (Bun required):

```sh
bun test/smoke.ts      # ~64 checks across 7 LSP sessions
```

---

## VSCode

```sh
cd vscode-extension
npm install
npm run compile
```

Then either:

**A. Run from source (dev loop).** Open the `vscode-extension/` directory in
VSCode and press <kbd>F5</kbd>. That launches an Extension Development Host
window where the extension is active. Open any `.jai` file or folder there.

**B. Use without the extension repo open.** Package the extension once:

```sh
npx @vscode/vsce package         # produces jai-lsp-vscode-0.0.1.vsix
code --install-extension jai-lsp-vscode-0.0.1.vsix
```

Then in your VSCode user settings, point at the binary:

```json
{
  "jai-lsp.serverPath": "/absolute/path/to/jai-lsp"
}
```

If the binary is on your `PATH`, you can leave the default (`"jai-lsp"`).

What you should see when it works: hovering an identifier shows it
back-ticked; <kbd>F12</kbd> jumps to definition across files in the workspace;
the outline pane lists top-level decls; lex errors get red squiggles.

---

## Zed

Zed needs a registered language to attach an LSP — it doesn't recognize
`.jai` files out of the box. Two options:

1. **Quick path:** Install a community Jai language extension from the Zed
   extensions registry (search "Jai" in the Extensions tab) and then add the
   LSP config below to `~/.config/zed/settings.json`:

   ```json
   {
     "lsp": {
       "jai-lsp": {
         "binary": {
           "path": "/absolute/path/to/jai-lsp",
           "arguments": []
         }
       }
     }
   }
   ```

2. **Local extension:** Author a minimal Zed extension that registers the
   `jai` language (file extension `.jai`) and points it at the binary above.
   See https://zed.dev/docs/extensions/languages for the format.

---

## Settings

| Key                       | Default     | Notes                                    |
| ------------------------- | ----------- | ---------------------------------------- |
| `jai-lsp.serverPath`      | `"jai-lsp"` | Absolute path or PATH-resolved binary    |
| `jai-lsp.trace.server`    | `"off"`     | LSP message trace level (VSCode)         |

---

## Troubleshooting

- **"jai-lsp failed to start"** — the binary isn't where the client looked.
  Set `jai-lsp.serverPath` to an absolute path.
- **No features in the editor** — open a folder (workspace) rather than a
  loose file; some features (definition, completion) rely on a workspace
  root that the client sends in `initialize`.
- **Server logs** — written to stderr; viewable in VSCode's
  "Output → Jai LSP" panel when `jai-lsp.trace.server` is `"verbose"`. Never
  goes to stdout (that channel is the LSP wire).

---

## Layout

```
build.jai              # `jai build.jai` -> ./jai-lsp
src/                   # the server (all Jai)
  main.jai             # entry point + read/dispatch loop
  rpc.jai              # Content-Length framing
  protocol.jai         # LSP types
  documents.jai        # open-doc store + position math (utf-8/16)
  analysis.jai         # Jai_Lexer wrapper: semantic tokens, decls, diagnostics
  workspace.jai        # workspace symbol index
  server.jai           # state, dispatch, lifecycle handlers
  log.jai              # stderr-only logging
test/
  smoke.ts             # bun-driven LSP smoke tests
vscode-extension/      # the ~50-line TS shim that spawns the binary
```
