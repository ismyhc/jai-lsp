# jai-lsp Zed extension

Registers the **Jai** language with Zed and wires up jai-lsp.

## Install (dev mode)

1. Build the jai-lsp binary at the repo root:
   ```sh
   cd .. && jai build.jai
   ```
2. Put `jai-lsp` somewhere on your PATH (or skip this and use the `binary.path`
   setting below):
   ```sh
   ln -s "$(pwd)/jai-lsp" /usr/local/bin/jai-lsp
   ```
3. In Zed: ⌘⇧P → **`zed: install dev extension`** → pick this directory.
4. **Configure the compiler path in Zed settings (⌘,) — this is required.**
   Zed sandboxes extensions so the LSP process doesn't inherit your shell
   PATH; without `compilerPath` set, diagnostics / hover-with-types /
   inlay hints won't work.

   ```jsonc
   {
       "lsp": {
           "jai-lsp": {
               // Skip if jai-lsp is on PATH:
               "binary": { "path": "/abs/path/to/jai-lsp" },
               "settings": {
                   "jai-lsp": {
                       "compilerPath": "/abs/path/to/jai/bin/jai-macos",
                       "entryFile":    "",
                       "inlayHints.enabled": true
                   }
               }
           }
       }
   }
   ```

Open a `.jai` file. Hover / Go-to-definition / outline should work
immediately.

## Caveats

- **`compilerPath` is effectively required.** Zed sandboxes extensions and
  `worktree.shell_env()` doesn't reliably surface the user's shell PATH,
  so the diagnostics subprocess can't find `jai` unless you give it an
  absolute path. Without it, hover-with-types / inlay hints / type def
  fall back to whatever stale data was in the AST sidecar.
- **Signature help.** Zed 1.3.6 doesn't dispatch `textDocument/signatureHelp`
  even with `auto_signature_help: true` set. Our server advertises and
  serves the capability — Zed just isn't asking. Newer Zed builds should
  fix this.
- **API version pinned.** Targets `zed_extension_api = "0.1.0"`. Compiles
  cleanly to `wasm32-wasip2`. If your Zed version expects a newer API,
  bump the dep in `Cargo.toml` and adjust `src/lib.rs` accordingly —
  the trait signature has changed between versions.

See the parent README for the full feature list and architecture overview.
