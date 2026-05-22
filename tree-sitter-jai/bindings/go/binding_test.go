package tree_sitter_jai_test

import (
	"testing"

	tree_sitter "github.com/tree-sitter/go-tree-sitter"
	tree_sitter_jai "github.com/constantitus/tree-sitter-jai/bindings/go"
)

func TestCanLoadGrammar(t *testing.T) {
	language := tree_sitter.NewLanguage(tree_sitter_jai.Language())
	if language == nil {
		t.Errorf("Error loading Jai grammar")
	}
}
