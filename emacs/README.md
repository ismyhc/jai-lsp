# jai-lsp for Emacs

A minimal Emacs package that registers `jai-ts-mode` for `.jai` files
(syntax highlighting + indentation via tree-sitter) and wires Eglot to
launch the `jai-lsp` binary for full LSP features.

**Requires Emacs 29+** (built-in `treesit` and `eglot`).

> **Status: lightly tested.** Eglot connects, file is recognized as Jai,
> tree-sitter highlighting works. Completion / signature-help / hover have
> not been thoroughly exercised by the project author; Eglot is supposed
> to surface all of them via standard commands (`completion-at-point`,
> Eldoc in the echo area, `C-h .`), but the exact keybindings and
> auto-popping behavior depend on your other Emacs configuration. If
> you've battle-tested this in real use, PRs welcome.

## Install

1. Build the `jai-lsp` binary at the repo root:
   ```sh
   jai build.jai
   ln -s "$(pwd)/jai-lsp" /usr/local/bin/jai-lsp   # or put it anywhere on PATH
   ```

2. Tell Emacs where the tree-sitter grammar lives, then install it:

   ```elisp
   (setq treesit-language-source-alist
         '((jai "https://github.com/<your-account>/jai-lsp" "master" "tree-sitter-jai/src")))
   ;; Then run once:
   ;; M-x treesit-install-language-grammar RET jai RET
   ```

3. Load the package. From this repo:

   ```elisp
   (add-to-list 'load-path "/abs/path/to/jai-lsp/emacs")
   (require 'jai-lsp)
   ```

   Or with `use-package`:

   ```elisp
   (use-package jai-lsp
     :load-path "/abs/path/to/jai-lsp/emacs"
     :mode ("\\.jai\\'" . jai-ts-mode))
   ```

4. Configure paths (`M-x customize-group RET jai-lsp RET`, or set in init):

   ```elisp
   (setq jai-lsp-server-path   "/abs/path/to/jai-lsp/jai-lsp"
         jai-lsp-compiler-path "/abs/path/to/jai/bin/jai-macos"
         jai-lsp-entry-file    "/abs/path/to/your/project/main.jai"
         jai-lsp-inlay-hints   t)
   ```

Open a `.jai` file. Eglot kicks in automatically. Hover (`C-h .`), Go to
Definition (`M-.`), Completion (`C-M-i` or company/corfu), and the rest of
the LSP feature set work as normal Eglot commands.

## Configuration

| Variable                  | Default     | Notes                                      |
| ------------------------- | ----------- | ------------------------------------------ |
| `jai-lsp-server-path`     | `"jai-lsp"` | Path to the LSP binary. PATH if bare       |
| `jai-lsp-compiler-path`   | `nil`       | Abs path to the Jai compiler (`jai-macos` / `jai-linux` / `jai.exe`). If unset the server falls back to looking for `jai` on PATH |
| `jai-lsp-entry-file`      | `nil`       | Project entry file. **Required for diagnostics** — without it they're suppressed to avoid cascade noise from standalone-file compiles |
| `jai-lsp-inlay-hints`     | `t`         | Inferred-type annotations after `:=`       |

Settings are forwarded to the server via env vars (`JAI_COMPILER`,
`JAI_LSP_ENTRY_FILE`, `JAI_LSP_INLAY_HINTS`) when the buffer enters
`jai-ts-mode`. Change a variable + revisit the buffer to apply.

## Status / known gaps

- **Font-lock coverage is a pragmatic subset** of the upstream tree-sitter
  queries (`tree-sitter-jai/queries/highlights.scm`). Most common
  constructs are colored; some edge cases (notes, polymorphic params,
  inline asm) aren't. Expand `jai-ts-mode--font-lock-settings` in
  `jai-lsp.el` to taste.
- **Indentation is brace-based** — covers blocks, struct/enum bodies,
  literals. Not as fancy as upstream's `indents.scm`.
- **Signature help via Eglot** — works (Eglot supports
  `textDocument/signatureHelp`; the server advertises the capability).
- **lsp-mode** users: this package only wires Eglot. lsp-mode users can
  copy the major-mode parts and use `lsp-mode`'s server configuration
  separately.
