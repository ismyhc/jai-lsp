// Jai_Lexer-driven analysis: semantic tokens, lex-level diagnostics, and
// top-level declaration extraction.
//
// This is the first file that puts actual Jai-language intelligence on the
// wire. Everything is derived from a single pass over the lexer; once we add
// a parser, that will live alongside (not replace) this code.

#import "Basic";
#import "Jai_Lexer";
#import "String";

// --- Semantic token legend -------------------------------------------------
//
// The order here defines the integer indices we emit on the wire — clients
// look them up in the legend we send during initialize. NEVER reorder this
// without bumping anything that depends on the indices.

// The order here defines the integer indices we emit on the wire. The legend
// is sent during initialize, so we can reshuffle freely as long as the
// constants below stay in sync with the array.
//
// Design rule: only emit semantic tokens for things we're CONFIDENT about.
// Anything we'd guess ("this identifier is probably a variable") should be
// left to the TextMate grammar — semantic tokens win the conflict, so a
// shallow classifier actively degrades coloring relative to the grammar.

SEMANTIC_TOKEN_TYPES :: string.[
    "keyword",   // 0 — Jai_Lexer KEYWORD_* range
    "string",    // 1 — STRING tokens
    "number",    // 2 — NUMBER tokens
    "function",  // 3 — names of `foo :: (` decls in this file
    "struct",    // 4 — names of `foo :: struct` decls in this file
    "enum",      // 5 — names of `foo :: enum` / `enum_flags` decls
];

SEMANTIC_TOKEN_MODIFIERS :: string.[
    // No modifiers yet.
];

ST_KEYWORD  :: 0;
ST_STRING   :: 1;
ST_NUMBER   :: 2;
ST_FUNCTION :: 3;
ST_STRUCT   :: 4;
ST_ENUM     :: 5;

// --- Semantic tokens + diagnostics -----------------------------------------
//
// Lexes `doc`, returns (semantic_tokens_data, diagnostics). Both are
// allocated on the temporary allocator — caller must serialize/forward
// before the next reset_temporary_storage().

analyze_document :: (doc: *Document, encoding: Position_Encoding) -> tokens: [] u32, diagnostics: [] Diagnostic {
    tokens:      [..] u32;       tokens.allocator      = temp;
    diagnostics: [..] Diagnostic; diagnostics.allocator = temp;

    if !doc.text.count return tokens, diagnostics;
    if has_unsafe_lexer_construct(doc.text) {
        log("Analysis: skipping % (contains lexer-tripping construct)", doc.uri);
        return tokens, diagnostics;
    }

    // Pre-scan top-level decls so the lex pass can classify identifier
    // tokens by their actual kind (function vs struct vs enum). This is
    // what avoids "every IDENT is `variable`" mush — only confident
    // classifications get emitted.
    decls := find_top_level_decls(doc.text);
    ident_kind: Table(string, Symbol_Kind);
    ident_kind.allocator = temp;
    for decls table_set(*ident_kind, it.name, it.kind);

    // Capture log output emitted by the lexer (`report_parse_error` calls
    // `log()`). Each captured chunk we treat as one diagnostic message.
    capture: Log_Capture;
    new_ctx := context;
    new_ctx.logger      = capture_logger;
    new_ctx.logger_data = *capture;

    push_context new_ctx {
        lexer: Lexer;
        set_input_from_string(*lexer, doc.text);

        prev_line: int = 0;
        prev_col:  int = 0;
        had_error := false;

        while true {
            tok := peek_next_token(*lexer);
            if tok.type == .END_OF_INPUT break;
            if lexer.reported_error {
                had_error = true;
                break;
            }

            sem := classify_token(tok, *ident_kind);
            if sem >= 0 emit_token(*tokens, doc, encoding, tok, sem, *prev_line, *prev_col);
            eat_token(*lexer);
        }

        if had_error || capture.messages.count > 0 {
            err_line := max(0, lexer.current_line_number - 1);
            err_col_bytes := max(0, lexer.current_character_index - 1);
            err_col := byte_col_to_encoding_col(doc.text, doc.line_starts, err_line, err_col_bytes, encoding);
            range := Range.{
                start = .{ line = err_line, character = err_col     },
                end   = .{ line = err_line, character = err_col + 1 },
            };
            for capture.messages {
                d := Diagnostic.{ range = range, message = trim(it) };
                array_add(*diagnostics, d);
            }
            if had_error && capture.messages.count == 0 {
                d := Diagnostic.{ range = range, message = "lex error" };
                array_add(*diagnostics, d);
            }
        }
    }

    return tokens, diagnostics;
}

// --- Top-level declaration extraction --------------------------------------
//
// Walks the token stream once, tracks brace depth, and yields the depth-0
// `IDENT :: <classifier>` patterns. Lexer-native byte coordinates (1-based)
// are preserved; callers convert to LSP coordinates as needed.

Top_Level_Decl :: struct {
    name:   string;          // identifier text (copied onto temp)
    kind:   Symbol_Kind;
    detail: string;          // "proc" | "struct" | "union" | "enum" | "enum_flags" | "constant"

    // Identifier extent in lexer coords (1-based byte offsets).
    l0, c0, l1, c1: s32;
}

find_top_level_decls :: (text: string) -> [] Top_Level_Decl {
    decls: [..] Top_Level_Decl;
    decls.allocator = temp;
    if !text.count return decls;
    if has_unsafe_lexer_construct(text) return decls;

    snaps: [..] Token_Snap;
    snaps.allocator = temp;

    new_ctx := context;
    new_ctx.allocator   = temp;             // ident atoms + lexer pool buckets on temp
    new_ctx.logger      = silence_logger;   // analyze_document is responsible for surfacing lex errors
    new_ctx.logger_data = null;

    push_context new_ctx {
        lexer: Lexer;
        set_input_from_string(*lexer, text);
        while true {
            tok := peek_next_token(*lexer);
            if tok.type == .END_OF_INPUT break;
            if lexer.reported_error break;

            s: Token_Snap;
            s.type = tok.type;
            s.l0   = tok.l0; s.c0 = tok.c0;
            s.l1   = tok.l1; s.c1 = tok.c1;
            if tok.type == .IDENT s.name = copy_string(tok.ident_value.name);
            array_add(*snaps, s);
            eat_token(*lexer);
        }
    }

    LBRACE :: cast(Token_Type) #char "{";
    RBRACE :: cast(Token_Type) #char "}";
    COLON  :: cast(Token_Type) #char ":";
    LPAREN :: cast(Token_Type) #char "(";

    depth := 0;
    i := 0;
    while i < snaps.count {
        t := snaps[i].type;

        if t == LBRACE { depth += 1; i += 1; continue; }
        if t == RBRACE { if depth > 0 then depth -= 1; i += 1; continue; }

        if depth == 0
            && t == .IDENT
            && i + 2 < snaps.count
            && snaps[i+1].type == COLON
            && snaps[i+2].type == COLON
        {
            kind   := Symbol_Kind.CONSTANT;
            detail := "constant";

            if i + 3 < snaps.count {
                nxt := snaps[i+3].type;
                if nxt == LPAREN                   { kind = .FUNCTION; detail = "proc"; }
                else if nxt == .KEYWORD_STRUCT     { kind = .STRUCT;   detail = "struct"; }
                else if nxt == .KEYWORD_UNION      { kind = .STRUCT;   detail = "union"; }
                else if nxt == .KEYWORD_ENUM       { kind = .ENUM;     detail = "enum"; }
                else if nxt == .KEYWORD_ENUM_FLAGS { kind = .ENUM;     detail = "enum_flags"; }
            }

            d: Top_Level_Decl;
            d.name = snaps[i].name; d.kind = kind; d.detail = detail;
            d.l0 = snaps[i].l0; d.c0 = snaps[i].c0;
            d.l1 = snaps[i].l1; d.c1 = snaps[i].c1;
            array_add(*decls, d);

            i += 3;
            continue;
        }

        i += 1;
    }

    return decls;
}

// --- Signature extraction (for signature help) -----------------------------
//
// For each `name :: (...)` decl in `text`, return its signature: the literal
// substring from `(` through the matching `)` and any following `-> Type`.
// We also compute parameter spans (byte offsets within the label) so the
// client can highlight the active parameter.
//
// Approach: lex `text` into snapshots once, then linearly scan for the
// pattern. No scope analysis — we return every match regardless of where
// it lives.

Extracted_Signature :: struct {
    label:        string;            // e.g. "(a: int, b: int) -> int"
    param_ranges: [] [2] int;        // [start, end) byte offsets into label
}

extract_signatures :: (text: string, target: string) -> [] Extracted_Signature {
    out: [..] Extracted_Signature;
    out.allocator = temp;
    if !text.count || !target.count return out;
    if has_unsafe_lexer_construct(text) return out;

    snaps := lex_to_snaps(text);
    if !snaps.count return out;

    line_starts := compute_line_starts(text);

    LPAREN :: cast(Token_Type) #char "(";
    RPAREN :: cast(Token_Type) #char ")";
    LBRACK :: cast(Token_Type) #char "[";
    RBRACK :: cast(Token_Type) #char "]";
    LBRACE :: cast(Token_Type) #char "{";
    RBRACE :: cast(Token_Type) #char "}";
    COLON  :: cast(Token_Type) #char ":";
    COMMA  :: cast(Token_Type) #char ",";

    i := 0;
    while i < snaps.count {
        if !(snaps[i].type == .IDENT
            && snaps[i].name == target
            && i + 2 < snaps.count
            && snaps[i+1].type == COLON
            && snaps[i+2].type == COLON)
        {
            i += 1;
            continue;
        }

        // Skip optional modifiers between `::` and the parameter list.
        j := i + 3;
        while j < snaps.count
            && (snaps[j].type == .KEYWORD_INLINE || snaps[j].type == .KEYWORD_NO_INLINE)
            j += 1;

        if j >= snaps.count || snaps[j].type != LPAREN {
            i += 1;
            continue;
        }

        sig := extract_one(text, snaps, j, line_starts);
        array_add(*out, sig);
        i = j + 1;  // continue past this decl
    }

    return out;
}

#scope_file

extract_one :: (text: string, snaps: [] Token_Snap, lparen_idx: int, line_starts: [] int) -> Extracted_Signature {
    LPAREN :: cast(Token_Type) #char "(";
    RPAREN :: cast(Token_Type) #char ")";
    LBRACK :: cast(Token_Type) #char "[";
    RBRACK :: cast(Token_Type) #char "]";
    LBRACE :: cast(Token_Type) #char "{";
    RBRACE :: cast(Token_Type) #char "}";
    COMMA  :: cast(Token_Type) #char ",";

    sig_start_byte := snap_start_byte(snaps[lparen_idx], line_starts);

    // Walk forward to find the matching `)`, recording parameter spans
    // (depth-0 commas split them).
    param_ranges_tmp: [..] [2] int;
    param_ranges_tmp.allocator = temp;

    param_start := sig_start_byte + 1;   // first byte after `(`
    rparen_idx := -1;
    depth := 0;
    k := lparen_idx + 1;
    while k < snaps.count {
        t := snaps[k].type;
        if t == LPAREN || t == LBRACK || t == LBRACE {
            depth += 1;
        } else if t == RBRACK || t == RBRACE {
            if depth > 0 depth -= 1;
        } else if t == RPAREN {
            if depth == 0 { rparen_idx = k; break; }
            depth -= 1;
        } else if t == COMMA && depth == 0 {
            comma_byte := snap_start_byte(snaps[k], line_starts);
            push_param(*param_ranges_tmp, sig_start_byte, param_start, comma_byte);
            param_start = snap_end_byte(snaps[k], line_starts);   // after the `,`
        }
        k += 1;
    }

    sig_end_byte: int;
    if rparen_idx < 0 {
        // Unbalanced — just take to end of text.
        sig_end_byte = text.count;
    } else {
        // Capture the last parameter if there was one.
        rparen_byte := snap_start_byte(snaps[rparen_idx], line_starts);
        push_param(*param_ranges_tmp, sig_start_byte, param_start, rparen_byte);

        // Then optionally extend through a `-> ReturnType` clause. Walk
        // forward past whitespace tokens (lexer skips whitespace anyway,
        // so just look at the next snap).
        sig_end_byte = snap_end_byte(snaps[rparen_idx], line_starts);
        if rparen_idx + 1 < snaps.count
            && snaps[rparen_idx + 1].type == .RIGHT_ARROW
        {
            // Include the `->` and the return-type expression. End-of-return-
            // type is heuristic: walk until we hit `{` (body), `;` (decl end),
            // or `#` (directive following) at depth 0.
            sig_end_byte = scan_return_type(snaps, rparen_idx + 1, line_starts, text);
        }
    }

    label: string;
    label.data  = text.data + sig_start_byte;
    label.count = sig_end_byte - sig_start_byte;

    // Convert param byte ranges from absolute-in-source to label-relative.
    param_ranges: [..] [2] int;
    param_ranges.allocator = temp;
    for r: param_ranges_tmp {
        array_add(*param_ranges, .[r[0], r[1]]);
    }

    return .{ label = label, param_ranges = param_ranges };
}

push_param :: (out: *[..] [2] int, sig_start_byte: int, param_start: int, param_end: int) {
    // Skip leading whitespace inside the param span; the lexer doesn't give
    // us whitespace tokens directly, but if the user wrote ` foo: int` the
    // span begins with a space. Trim only at the start.
    array_add(out, .[param_start - sig_start_byte, param_end - sig_start_byte]);
}

scan_return_type :: (snaps: [] Token_Snap, start_idx: int, line_starts: [] int, text: string) -> int {
    LPAREN :: cast(Token_Type) #char "(";
    RPAREN :: cast(Token_Type) #char ")";
    LBRACK :: cast(Token_Type) #char "[";
    RBRACK :: cast(Token_Type) #char "]";
    LBRACE :: cast(Token_Type) #char "{";
    SEMI   :: cast(Token_Type) #char ";";

    depth := 0;
    last_end := snap_end_byte(snaps[start_idx], line_starts);
    k := start_idx;
    while k < snaps.count {
        t := snaps[k].type;
        if t == LBRACE && depth == 0 break;       // proc body
        if t == SEMI   && depth == 0 break;       // forward decl
        if t == LPAREN || t == LBRACK            depth += 1;
        else if t == RPAREN || t == RBRACK       depth = ifx depth > 0 then depth - 1 else 0;
        last_end = snap_end_byte(snaps[k], line_starts);
        k += 1;
    }
    return last_end;
}

snap_start_byte :: (s: Token_Snap, line_starts: [] int) -> int {
    line := cast(int) s.l0 - 1;
    col  := cast(int) s.c0 - 1;
    if line < 0 || line >= line_starts.count return 0;
    return line_starts[line] + col;
}

snap_end_byte :: (s: Token_Snap, line_starts: [] int) -> int {
    line := cast(int) s.l1 - 1;
    col  := cast(int) s.c1 - 1;
    if line < 0 || line >= line_starts.count return 0;
    return line_starts[line] + col;
}

#scope_export

// Collect tokens from `text` into a snapshot array — shared by symbol/
// reference/signature extraction. Allocates on temp.
lex_to_snaps :: (text: string) -> [] Token_Snap {
    snaps: [..] Token_Snap;
    snaps.allocator = temp;
    if !text.count return snaps;

    new_ctx := context;
    new_ctx.allocator   = temp;
    new_ctx.logger      = silence_logger;
    new_ctx.logger_data = null;

    push_context new_ctx {
        lexer: Lexer;
        set_input_from_string(*lexer, text);
        while true {
            tok := peek_next_token(*lexer);
            if tok.type == .END_OF_INPUT break;
            if lexer.reported_error break;
            s: Token_Snap;
            s.type = tok.type;
            s.l0   = tok.l0; s.c0 = tok.c0;
            s.l1   = tok.l1; s.c1 = tok.c1;
            if tok.type == .IDENT s.name = copy_string(tok.ident_value.name);
            array_add(*snaps, s);
            eat_token(*lexer);
        }
    }
    return snaps;
}

// --- Identifier occurrences (for find-references) --------------------------
//
// Returns every IDENT token in `text` whose name equals `target`, tagged
// with whether it's a declaration site (`IDENT ::` pattern) or a plain
// reference. We don't do scope analysis — same-name decls at different
// scopes all come back; the LSP caller can choose whether to include them.

Ident_Occurrence :: struct {
    l0, c0, l1, c1: s32;     // 1-based byte coords
    is_decl:        bool;    // followed by `::`
}

find_ident_occurrences :: (text: string, target: string) -> [] Ident_Occurrence {
    out: [..] Ident_Occurrence;
    out.allocator = temp;
    if !text.count return out;
    if !target.count return out;
    if has_unsafe_lexer_construct(text) return out;

    snaps: [..] Token_Snap;
    snaps.allocator = temp;

    new_ctx := context;
    new_ctx.allocator   = temp;
    new_ctx.logger      = silence_logger;
    new_ctx.logger_data = null;

    push_context new_ctx {
        lexer: Lexer;
        set_input_from_string(*lexer, text);
        while true {
            tok := peek_next_token(*lexer);
            if tok.type == .END_OF_INPUT break;
            if lexer.reported_error break;

            s: Token_Snap;
            s.type = tok.type;
            s.l0   = tok.l0; s.c0 = tok.c0;
            s.l1   = tok.l1; s.c1 = tok.c1;
            if tok.type == .IDENT s.name = copy_string(tok.ident_value.name);
            array_add(*snaps, s);
            eat_token(*lexer);
        }
    }

    COLON :: cast(Token_Type) #char ":";
    for i: 0..snaps.count - 1 {
        if snaps[i].type != .IDENT continue;
        if snaps[i].name != target continue;
        is_decl := i + 2 < snaps.count
                && snaps[i+1].type == COLON
                && snaps[i+2].type == COLON;
        occ: Ident_Occurrence;
        occ.l0 = snaps[i].l0; occ.c0 = snaps[i].c0;
        occ.l1 = snaps[i].l1; occ.c1 = snaps[i].c1;
        occ.is_decl = is_decl;
        array_add(*out, occ);
    }
    return out;
}

// --- Folding ranges --------------------------------------------------------
//
// Each matched `{` ... `}` pair produces one fold spanning the `{` line
// through the line BEFORE the `}` (so the closing brace stays visible when
// folded). Inclusive endLine per LSP spec; same-line braces produce no fold.

compute_folding_ranges :: (text: string) -> [] Folding_Range {
    ranges: [..] Folding_Range;
    ranges.allocator = temp;
    if !text.count return ranges;
    if has_unsafe_lexer_construct(text) return ranges;

    LBRACE :: cast(Token_Type) #char "{";
    RBRACE :: cast(Token_Type) #char "}";

    // Stack of open-brace line numbers (0-based).
    open_lines: [..] int;
    open_lines.allocator = temp;

    new_ctx := context;
    new_ctx.allocator   = temp;
    new_ctx.logger      = silence_logger;
    new_ctx.logger_data = null;

    push_context new_ctx {
        lexer: Lexer;
        set_input_from_string(*lexer, text);
        while true {
            tok := peek_next_token(*lexer);
            if tok.type == .END_OF_INPUT break;
            if lexer.reported_error break;

            if tok.type == LBRACE {
                line := cast(int) tok.l0 - 1;
                if line < 0 line = 0;
                array_add(*open_lines, line);
            } else if tok.type == RBRACE {
                if open_lines.count > 0 {
                    start_line := open_lines[open_lines.count - 1];
                    open_lines.count -= 1;

                    end_line := cast(int) tok.l0 - 1;
                    if end_line < 0 end_line = 0;
                    // Drop folds that don't span multiple lines.
                    if end_line - 1 > start_line {
                        array_add(*ranges, Folding_Range.{
                            startLine = start_line,
                            endLine   = end_line - 1,
                        });
                    }
                }
            }
            eat_token(*lexer);
        }
    }

    return ranges;
}

// --- Document symbols ------------------------------------------------------

collect_document_symbols :: (doc: *Document, encoding: Position_Encoding) -> [] Document_Symbol {
    symbols: [..] Document_Symbol;
    symbols.allocator = temp;

    decls := find_top_level_decls(doc.text);
    for decls {
        sel := decl_to_range(doc.text, doc.line_starts, it, encoding);
        sym := Document_Symbol.{
            name           = it.name,
            detail         = it.detail,
            kind           = cast(int) it.kind,
            range          = sel,   // TODO: span the whole body for struct/enum/proc
            selectionRange = sel,
        };
        array_add(*symbols, sym);
    }
    return symbols;
}

// Convert a Top_Level_Decl's lexer-native byte coords into an LSP Range using
// the negotiated encoding.
decl_to_range :: (text: string, line_starts: [] int, decl: Top_Level_Decl, encoding: Position_Encoding) -> Range {
    line0 := cast(int) decl.l0 - 1;
    line1 := cast(int) decl.l1 - 1;
    if line0 < 0 line0 = 0;
    if line1 < line0 line1 = line0;

    col0_bytes := cast(int) decl.c0 - 1;
    col1_bytes := cast(int) decl.c1 - 1;
    if col0_bytes < 0 col0_bytes = 0;
    if col1_bytes < 0 col1_bytes = col0_bytes;

    r: Range;
    r.start.line      = line0;
    r.start.character = byte_col_to_encoding_col(text, line_starts, line0, col0_bytes, encoding);
    r.end.line        = line1;
    r.end.character   = byte_col_to_encoding_col(text, line_starts, line1, col1_bytes, encoding);
    return r;
}

// --- Internals -------------------------------------------------------------

Token_Snap :: struct {
    type:           Token_Type;
    l0, c0, l1, c1: s32;
    name:           string;     // populated for IDENT
}

classify_token :: (tok: *Token, ident_kind: *Table(string, Symbol_Kind)) -> int {
    t := tok.type;
    if t == .STRING return ST_STRING;
    if t == .NUMBER return ST_NUMBER;

    if t == .IDENT {
        // Only classify identifiers we have certainty about. Plain variables
        // and cross-file references stay un-tokenized so the TextMate
        // grammar's coloring wins.
        found, kind := table_find(ident_kind, tok.ident_value.name);
        if !found return -1;
        if kind == .FUNCTION return ST_FUNCTION;
        if kind == .STRUCT   return ST_STRUCT;
        if kind == .ENUM     return ST_ENUM;
        return -1;   // constants etc. — leave to grammar
    }

    int_t := cast(s32) t;
    first_kw := cast(s32) Token_Type.__FIRST_KEYWORD;
    last_kw  := cast(s32) Token_Type.__LAST_KEYWORD;
    if int_t >= first_kw && int_t <= last_kw return ST_KEYWORD;

    return -1;
}

emit_token :: (
    out: *[..] u32,
    doc: *Document,
    encoding: Position_Encoding,
    tok: *Token,
    sem_type: int,
    prev_line: *int,
    prev_col:  *int,
) {
    // Lexer line/col are 1-based byte offsets. LSP wants 0-based offsets
    // in the negotiated encoding.
    line0 := cast(int) tok.l0 - 1;
    col0_bytes := cast(int) tok.c0 - 1;
    if line0 < 0 || line0 >= doc.line_starts.count return;

    col0 := byte_col_to_encoding_col(doc.text, doc.line_starts, line0, col0_bytes, encoding);

    length: int;
    if tok.l1 == tok.l0 && tok.c1 >= tok.c0 {
        col1_bytes := cast(int) tok.c1 - 1;
        col1 := byte_col_to_encoding_col(doc.text, doc.line_starts, line0, col1_bytes, encoding);
        length = col1 - col0;
    } else {
        length = line_length_in_encoding_units(doc.text, doc.line_starts, line0, encoding) - col0;
    }
    if length <= 0 return;

    delta_line  := line0 - prev_line.*;
    delta_start := ifx delta_line == 0 then col0 - prev_col.* else col0;

    array_add(out, cast(u32) delta_line);
    array_add(out, cast(u32) delta_start);
    array_add(out, cast(u32) length);
    array_add(out, cast(u32) sem_type);
    array_add(out, cast(u32) 0);   // modifiers bitmask — none for now

    prev_line.* = line0;
    prev_col.*  = col0;
}

silence_logger :: (message: string, data: *void, info: Log_Info) {
    // intentionally empty
}

// The bundled Jai_Lexer crashes (NULL deref inside compose_new_token) on the
// `#string,<modifier>` herestring syntax — observed with `#string,\%`. Until
// the upstream lexer is fixed, treat any file containing that pattern as
// off-limits for analysis. We lose features for that file but the server
// stays up. Pattern is rare; one file in the entire Jai distribution as of
// this writing (how_to/018_print_functions.jai).
has_unsafe_lexer_construct :: (text: string) -> bool {
    found, _ := contains(text, "#string,");
    return found;
}

// --- Log capture (for lexer error messages) --------------------------------

Log_Capture :: struct {
    messages: [..] string;
}

capture_logger :: (message: string, data: *void, info: Log_Info) {
    if !data return;
    cap := cast(*Log_Capture) data;
    cap.messages.allocator = temp;
    s := copy_string(message,, temp);
    array_add(*cap.messages, s);
}
