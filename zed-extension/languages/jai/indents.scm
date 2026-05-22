; Zed's tree-sitter indentation captures:
;   @indent    increase indent for the next line after this node
;   @end       decrease indent at this node
;   @outdent   explicit dedent (we don't need it here)
;
; The upstream nvim-treesitter indents.scm used @indent.begin / @indent.end
; which Zed doesn't recognize, so this is the Zed-flavored rewrite.

[
  "{"
  "("
  "["
] @indent

[
  "}"
  ")"
  "]"
] @end
