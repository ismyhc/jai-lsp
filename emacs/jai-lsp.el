;;; jai-lsp.el --- Major mode + LSP wiring for Jai  -*- lexical-binding: t; -*-

;; Author: Jacob Davis
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, jai
;; URL: https://github.com/<your-account>/jai-lsp

;;; Commentary:

;; A small Emacs package that:
;;   - Registers `jai-ts-mode' as the major mode for *.jai files, using
;;     the bundled tree-sitter-jai grammar for syntax highlighting and
;;     indentation.
;;   - Wires up Eglot to launch the `jai-lsp' binary, forwarding
;;     user-configurable settings (compiler path, entry file, inlay
;;     hints) as environment variables.
;;
;; First-time setup:
;;   1. Build and install the jai-lsp binary (see the top-level README).
;;   2. (M-x) `treesit-install-language-grammar' RET jai RET to fetch the
;;      grammar, after configuring `treesit-language-source-alist' as
;;      shown in the README below.
;;   3. `(require 'jai-lsp)' in your init file.
;;
;; Per-user configuration (M-x customize-group RET jai-lsp RET):
;;   - `jai-lsp-server-path'    — path to jai-lsp binary
;;   - `jai-lsp-compiler-path'  — path to the Jai compiler (required for
;;                                AST features in sandboxed editors;
;;                                Emacs inherits PATH so usually OK)
;;   - `jai-lsp-entry-file'     — project entry file (required for
;;                                diagnostics)
;;   - `jai-lsp-inlay-hints'    — emit inlay hints (default on)

;;; Code:

(require 'treesit)
(require 'eglot)

;; ---- User configuration ----------------------------------------------------

(defgroup jai-lsp nil
  "Jai language support backed by the jai-lsp server."
  :group 'languages
  :prefix "jai-lsp-")

(defcustom jai-lsp-server-path "jai-lsp"
  "Path to the jai-lsp binary. PATH is searched if unqualified."
  :type 'string
  :group 'jai-lsp)

(defcustom jai-lsp-auto-install t
  "If non-nil and `jai-lsp-server-path' doesn't resolve to an executable
and `jai-lsp' isn't on PATH, download the binary matching `jai-lsp-version'
into `jai-lsp-binary-cache-dir' and use that instead."
  :type 'boolean
  :group 'jai-lsp)

(defcustom jai-lsp-version "v0.1.0"
  "GitHub release tag to download from when auto-installing."
  :type 'string
  :group 'jai-lsp)

(defcustom jai-lsp-github-repo "ismyhc/jai-lsp"
  "GitHub repo (owner/name) to fetch release binaries from."
  :type 'string
  :group 'jai-lsp)

(defcustom jai-lsp-binary-cache-dir
  (expand-file-name "jai-lsp/" user-emacs-directory)
  "Local cache directory for downloaded jai-lsp binaries."
  :type 'directory
  :group 'jai-lsp)

(defcustom jai-lsp-compiler-path nil
  "Absolute path to the Jai compiler binary.
Forwarded to the server as the JAI_COMPILER env var. Needed for
diagnostics and AST-backed features. If nil, the server falls back
to looking for `jai' on PATH."
  :type '(choice (const :tag "Use PATH" nil) string)
  :group 'jai-lsp)

(defcustom jai-lsp-entry-file nil
  "Absolute path to your project's entry file (the one with `main :: ()').
Forwarded as JAI_LSP_ENTRY_FILE. Without this, diagnostics are
suppressed (standalone leaf-file compiles tend to produce cascade
noise). Hover-with-types / inlay hints still work without it."
  :type '(choice (const :tag "None — diagnostics suppressed" nil) string)
  :group 'jai-lsp)

(defcustom jai-lsp-inlay-hints t
  "Whether the server should emit inlay hints (inferred-type annotations
like `: s64' after `x :='). Forwarded as JAI_LSP_INLAY_HINTS."
  :type 'boolean
  :group 'jai-lsp)

(defun jai-lsp--apply-env ()
  "Push jai-lsp settings into the process environment so the spawned
LSP subprocess sees them."
  (when (and jai-lsp-compiler-path (not (string-empty-p jai-lsp-compiler-path)))
    (setenv "JAI_COMPILER" jai-lsp-compiler-path))
  (when (and jai-lsp-entry-file (not (string-empty-p jai-lsp-entry-file)))
    (setenv "JAI_LSP_ENTRY_FILE" jai-lsp-entry-file))
  (setenv "JAI_LSP_INLAY_HINTS" (if jai-lsp-inlay-hints "1" "0")))

;; ---- Binary auto-install ---------------------------------------------------

(defun jai-lsp--platform-name ()
  "Return ((os . arch) ext) matching jai-lsp's release binary naming."
  (let* ((os   (cond ((eq system-type 'darwin)     "darwin")
                     ((eq system-type 'gnu/linux)  "linux")
                     ((memq system-type '(windows-nt cygwin ms-dos)) "windows")
                     (t                            (symbol-name system-type))))
         (arch (cond ((string-match-p "aarch64\\|arm64" system-configuration) "arm64")
                     ((string-match-p "x86_64\\|amd64"  system-configuration) "x64")
                     (t                                                        "x64")))
         (ext  (if (string= os "windows") ".exe" "")))
    (list os arch ext)))

(defun jai-lsp--executable-p (path)
  (and path (not (string-empty-p path))
       (or (and (file-name-absolute-p path) (file-executable-p path))
           (and (not (file-name-absolute-p path)) (executable-find path)))))

(defun jai-lsp--ensure-binary ()
  "Return the resolved path to the jai-lsp binary.
Resolution order:
  1. `jai-lsp-server-path' if it points at an executable.
  2. `jai-lsp' on PATH.
  3. If `jai-lsp-auto-install' is non-nil, download the matching release
     binary into the cache dir and return that path."
  (cond
   ((jai-lsp--executable-p jai-lsp-server-path) jai-lsp-server-path)
   ((executable-find "jai-lsp")                  "jai-lsp")
   (jai-lsp-auto-install
    (cl-destructuring-bind (os arch ext) (jai-lsp--platform-name)
      (let* ((name      (format "jai-lsp-%s-%s%s" os arch ext))
             (cache-dir (file-name-as-directory
                         (expand-file-name jai-lsp-version
                                           jai-lsp-binary-cache-dir)))
             (dest      (expand-file-name name cache-dir))
             (url       (format "https://github.com/%s/releases/download/%s/%s"
                                jai-lsp-github-repo jai-lsp-version name)))
        (unless (file-executable-p dest)
          (make-directory cache-dir t)
          (message "jai-lsp: downloading %s ..." name)
          ;; Prefer curl; fall back to url-copy-file if curl is missing.
          (let ((curl (executable-find "curl")))
            (if curl
                (let ((rc (call-process curl nil nil nil
                                        "-fL" "--silent" "--show-error"
                                        "-o" dest url)))
                  (unless (zerop rc)
                    (error "jai-lsp: curl failed (exit %d) for %s" rc url)))
              (url-copy-file url dest 'ok-if-exists)))
          (unless (string= os "windows")
            (set-file-modes dest #o755))
          (message "jai-lsp: download complete (%s)" dest))
        dest)))
   (t jai-lsp-server-path)))   ; fallthrough — let Eglot surface "not found"

;; ---- Tree-sitter font-lock -------------------------------------------------
;;
;; A pragmatic subset of the upstream queries/highlights.scm rewritten as
;; treesit-font-lock rules. Doesn't cover everything the grammar can
;; classify; tighten over time. The grammar's own scm queries can be
;; consulted directly for richer coverage if you prefer to load them via
;; `treesit-query-compile'.

(defvar jai-ts-mode--font-lock-settings
  (treesit-font-lock-rules
   :language 'jai
   :feature 'comment
   '((comment)       @font-lock-comment-face
     (block_comment) @font-lock-comment-face)

   :language 'jai
   :feature 'string
   '((string) @font-lock-string-face)

   :language 'jai
   :feature 'number
   '((integer) @font-lock-number-face
     (float)   @font-lock-number-face)

   :language 'jai
   :feature 'constant
   '((boolean) @font-lock-constant-face
     (null)    @font-lock-constant-face)

   :language 'jai
   :feature 'keyword
   '(["if" "ifx" "then" "else" "case" "for" "while" "break" "continue"
      "return" "defer" "remove" "using" "push_context"
      "struct" "union" "enum" "enum_flags" "interface" "operator"
      "inline" "no_inline" "cast" "xx"]
     @font-lock-keyword-face)

   :language 'jai
   :feature 'directive
   '((compiler_directive) @font-lock-preprocessor-face)

   :language 'jai
   :feature 'definition
   '((procedure_declaration (identifier) @font-lock-function-name-face)
     (struct_declaration    (identifier) @font-lock-type-face)
     (enum_declaration      (identifier) @font-lock-type-face))

   :language 'jai
   :feature 'function
   '((call_expression function: (identifier) @font-lock-function-call-face))

   :language 'jai
   :feature 'type
   '((types (identifier) @font-lock-type-face)
     ((identifier) @font-lock-type-face
      (:match "^[A-Z][A-Za-z0-9_]*[a-z][A-Za-z0-9_]*$" @font-lock-type-face)))

   :language 'jai
   :feature 'builtin
   '(((identifier) @font-lock-constant-face
      (:match "^_*[A-Z][A-Z0-9_]*$" @font-lock-constant-face))
     (import (identifier) @font-lock-builtin-face))

   :language 'jai
   :feature 'variable
   '((parameter (identifier) @font-lock-variable-name-face)
     (member_expression "." (identifier) @font-lock-property-use-face)))
  "Font-lock rules for `jai-ts-mode'.

  Each :feature block compiles a separate query — if ANY node name in a
  block is unknown to the grammar, the whole block silently fails. That's
  the trap that bit the first version of this; keep node names in sync
  with what tree-sitter-jai/grammar.js actually produces.")

;; ---- Indentation -----------------------------------------------------------

(defvar jai-ts-mode--indent-rules
  '((jai
     ((parent-is "source_file") column-0 0)
     ((node-is "}")             parent-bol 0)
     ((node-is ")")             parent-bol 0)
     ((node-is "]")             parent-bol 0)
     ((parent-is "block")       parent-bol 4)
     ((parent-is "struct_or_union_block") parent-bol 4)
     ((parent-is "enum_declaration")      parent-bol 4)
     ((parent-is "struct_literal")        parent-bol 4)
     ((parent-is "array_literal")         parent-bol 4)
     (no-node parent-bol 0)))
  "Indent rules for `jai-ts-mode'.")

;; ---- Major mode ------------------------------------------------------------

;;;###autoload
(define-derived-mode jai-ts-mode prog-mode "Jai"
  "Major mode for editing Jai source files, backed by tree-sitter."
  :group 'jai-lsp
  (setq-local comment-start      "// ")
  (setq-local comment-end        "")
  (setq-local comment-start-skip "//+\\s-*")
  (setq-local indent-tabs-mode   nil)
  (setq-local tab-width          4)
  (when (treesit-ready-p 'jai)
    (treesit-parser-create 'jai)
    (setq-local treesit-font-lock-settings jai-ts-mode--font-lock-settings)
    (setq-local treesit-font-lock-feature-list
                '((comment string)
                  (keyword constant directive)
                  (definition function type number builtin)
                  (variable)))
    (setq-local treesit-simple-indent-rules jai-ts-mode--indent-rules)
    (treesit-major-mode-setup)))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.jai\\'" . jai-ts-mode))

;; ---- Eglot integration -----------------------------------------------------

;;;###autoload
(with-eval-after-load 'eglot
  ;; Register a contact LAMBDA so the binary is resolved at attach time —
  ;; not at startup, when we may not yet know which path to use.
  (add-to-list 'eglot-server-programs
               '(jai-ts-mode . (lambda (_) (list (jai-lsp--ensure-binary))))))

(defun jai-lsp--maybe-start-eglot ()
  "Run on `jai-ts-mode-hook'. Forwards settings then starts Eglot."
  (require 'cl-lib)
  (jai-lsp--apply-env)
  (when (fboundp 'eglot-ensure)
    (eglot-ensure)))

(add-hook 'jai-ts-mode-hook #'jai-lsp--maybe-start-eglot)

(provide 'jai-lsp)
;;; jai-lsp.el ends here
