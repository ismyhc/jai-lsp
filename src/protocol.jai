// LSP protocol types. We declare only the shapes we actually need at this
// milestone; jaison maps field names to JSON keys, so the LSP camelCase
// convention is preserved verbatim in Jai field names.
//
// Conventions:
//   * Optional JSON fields are modelled as pointers (`*int`, `*string`, ...).
//     A null pointer means the field is omitted in serialization and is absent
//     in deserialized input.
//   * `id` is a special case in JSON-RPC: it may be a number or a string.
//     We treat it as `*JSON_Value` so we can preserve the client's original
//     type and echo it back unchanged in responses.

#import "jaison";

// --- Response envelopes -----------------------------------------------------
//
// JSON-RPC requires that a response contain EXACTLY one of `result` or
// `error`, not both, and the absent one must be omitted (not present-as-null).
// jaison serializes a null pointer field as `"name": null`, which would
// violate that — so we don't model the envelope as a struct here. Instead,
// the dispatcher composes the envelope manually around a serialized payload
// (see send_result / send_error in server.jai).

Response_Error :: struct {
    code:    int;
    message: string;
    // data: *JSON_Value;  // optional, omitted until a handler needs it
}

// JSON-RPC error codes we actually use. Full list is in the LSP spec.
ERROR_PARSE_ERROR      :: -32700;
ERROR_INVALID_REQUEST  :: -32600;
ERROR_METHOD_NOT_FOUND :: -32601;
ERROR_INVALID_PARAMS   :: -32602;
ERROR_INTERNAL_ERROR   :: -32603;

// --- initialize -------------------------------------------------------------

Initialize_Result :: struct {
    capabilities: Server_Capabilities;
    serverInfo:   Server_Info;
}

Server_Info :: struct {
    name:    string = "jai-lsp";
    version: string = "0.0.1";
}

// Capability flags we advertise. Keep this in sync with what handlers actually
// implement — clients call methods based on what we claim here.
Server_Capabilities :: struct {
    // Full-document sync, plus explicit opt-in to open/close and save events
    // (clients won't deliver didSave unless we advertise it).
    textDocumentSync:       Text_Document_Sync_Options;
    hoverProvider:          bool = true;
    documentSymbolProvider:  bool = true;
    definitionProvider:      bool = true;
    referencesProvider:      bool = true;
    workspaceSymbolProvider: bool = true;
    foldingRangeProvider:    bool = true;
    completionProvider:      Completion_Options;
    signatureHelpProvider:   Signature_Help_Options;

    // The actual encoding we picked during initialize negotiation. Filled in
    // by the handler before serialization.
    positionEncoding: string = "utf-16";

    // Semantic tokens (full-document only for now). The `legend` MUST line up
    // with the indices we emit in analysis.jai — see SEMANTIC_TOKEN_TYPES.
    semanticTokensProvider: Semantic_Tokens_Options;
}

Semantic_Tokens_Options :: struct {
    legend: Semantic_Tokens_Legend;
    range:  bool = false;
    full:   bool = true;
}

Semantic_Tokens_Legend :: struct {
    tokenTypes:     [] string;
    tokenModifiers: [] string;
}

Semantic_Tokens :: struct {
    // resultId: string;  // omitted; we don't support deltas yet
    data: [] u32;
}

// --- Diagnostics ------------------------------------------------------------

Diagnostic_Severity :: enum {
    ERROR       :: 1;
    WARNING     :: 2;
    INFORMATION :: 3;
    HINT        :: 4;
}

Diagnostic :: struct {
    range:    Range;
    severity: int    = 1;          // jaison would emit enum names as strings; LSP wants integers
    source:   string = "jai-lsp";
    message:  string;
}

Publish_Diagnostics_Params :: struct {
    uri:         string;
    version:     int;
    diagnostics: [] Diagnostic;
}

// --- Document symbols -------------------------------------------------------
//
// LSP SymbolKind is a numeric enum the spec defines. We only assign the kinds
// we actually emit; everything else stays unused.

Symbol_Kind :: enum {
    FILE         :: 1;
    MODULE       :: 2;
    NAMESPACE    :: 3;
    PACKAGE      :: 4;
    CLASS        :: 5;
    METHOD       :: 6;
    PROPERTY     :: 7;
    FIELD        :: 8;
    CONSTRUCTOR  :: 9;
    ENUM         :: 10;
    INTERFACE    :: 11;
    FUNCTION     :: 12;
    VARIABLE     :: 13;
    CONSTANT     :: 14;
    STRING       :: 15;
    NUMBER       :: 16;
    BOOLEAN      :: 17;
    ARRAY        :: 18;
    OBJECT       :: 19;
    KEY          :: 20;
    NULL_KIND    :: 21;
    ENUM_MEMBER  :: 22;
    STRUCT       :: 23;
    EVENT        :: 24;
    OPERATOR     :: 25;
    TYPE_PARAM   :: 26;
}

Document_Symbol :: struct {
    name:            string;
    detail:          string;             // e.g. "proc", "struct", "constant"
    kind:            int;                // see Symbol_Kind; int because jaison would write enum names as strings
    range:           Range;              // full extent of the declaration
    selectionRange:  Range;              // the identifier itself
    children:        [] Document_Symbol; // omitted-as-empty for top-level-only emission
}

// --- Definition / Completion ------------------------------------------------

Location :: struct {
    uri:   string;
    range: Range;
}

// LSP SymbolInformation, used as the response item for workspace/symbol.
// Distinct from Document_Symbol (which is hierarchical, used for the
// per-file outline). Name with the LSP_ prefix to avoid colliding with our
// internal Workspace_Symbol struct in workspace.jai.
LSP_Workspace_Symbol :: struct {
    name:          string;
    kind:          int;        // see Symbol_Kind
    location:      Location;
    containerName: string;     // optional but harmless to send; we leave it blank
}

// --- Signature help ---------------------------------------------------------

Signature_Help_Options :: struct {
    triggerCharacters:   [] string = .["("];
    retriggerCharacters: [] string = .[","];
}

Signature_Help :: struct {
    signatures:      [] Signature_Information;
    activeSignature: int = 0;
    activeParameter: int = 0;
}

Signature_Information :: struct {
    label:      string;                   // e.g. "(a: int, b: int) -> int"
    parameters: [] Parameter_Information;
    // documentation: omitted until we extract doc comments
}

Parameter_Information :: struct {
    // [start, end] byte-offset pair into the signature label. Using
    // offsets instead of substring matching avoids ambiguity.
    label: [2] int;
}

// --- Folding ranges ---------------------------------------------------------

Folding_Range :: struct {
    startLine: int;
    endLine:   int;
    kind:      string = "region";   // "comment" | "imports" | "region"
    // startCharacter / endCharacter intentionally omitted — the LSP spec
    // says clients fold the whole line when those are absent, which is
    // what we want for brace-based folds.
}

Completion_Options :: struct {
    // triggerCharacters / resolveProvider / completionItem can come later.
    // jaison emits the bare {} when no fields are set, which is a valid
    // CompletionOptions value per the spec.
}

// CompletionItemKind enum values (LSP spec). Same int-vs-enum dance as
// Symbol_Kind — jaison would serialize names; we want numbers.
Completion_Item_Kind :: enum {
    TEXT          :: 1;
    METHOD        :: 2;
    FUNCTION      :: 3;
    CONSTRUCTOR   :: 4;
    FIELD         :: 5;
    VARIABLE      :: 6;
    CLASS         :: 7;
    INTERFACE     :: 8;
    MODULE        :: 9;
    PROPERTY      :: 10;
    UNIT          :: 11;
    VALUE         :: 12;
    ENUM          :: 13;
    KEYWORD       :: 14;
    SNIPPET       :: 15;
    COLOR         :: 16;
    FILE          :: 17;
    REFERENCE     :: 18;
    FOLDER        :: 19;
    ENUM_MEMBER   :: 20;
    CONSTANT      :: 21;
    STRUCT        :: 22;
    EVENT         :: 23;
    OPERATOR      :: 24;
    TYPE_PARAM    :: 25;
}

Completion_Item :: struct {
    label:  string;
    kind:   int;             // see Completion_Item_Kind
    detail: string;
}

Completion_List :: struct {
    isIncomplete: bool = false;
    items:        [] Completion_Item;
}

// --- Position / range -------------------------------------------------------

Text_Document_Sync_Options :: struct {
    openClose: bool                       = true;
    change:    int                        = 1;     // Full sync
    save:      Text_Document_Save_Options;
}

Text_Document_Save_Options :: struct {
    includeText: bool = false;   // we re-read from disk in run_check anyway
}

Position :: struct {
    line:      int;   // 0-based
    character: int;   // 0-based; units depend on negotiated positionEncoding
}

Range :: struct {
    start: Position;
    end:   Position;
}

// --- Text document sync -----------------------------------------------------

Text_Document_Item :: struct {
    uri:        string;
    languageId: string;
    version:    int;
    text:       string;
}

Versioned_Text_Document_Identifier :: struct {
    uri:     string;
    version: int;
}

Text_Document_Identifier :: struct {
    uri: string;
}

// --- Hover ------------------------------------------------------------------

Hover_Result :: struct {
    contents: string;   // simple Markdown/plain-text form; richer forms
                        // (MarkupContent, MarkedString[]) can come later.
    // range: *Range;   // optional; we omit it for the stub.
}
