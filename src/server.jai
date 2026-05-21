// Server state, dispatch table, and lifecycle handlers.
//
// `handle_message` is the per-message entry point. It:
//   1. Parses the JSON body into a generic JSON_Value (the envelope).
//   2. Reads `method` and (optionally) `id`.
//   3. Dispatches to the matching handler.
//   4. For requests (id present), writes a framed response. For notifications
//      (no id), sends nothing.
//
// All per-message allocations land on temporary storage. The caller in
// main.jai resets temp storage after each iteration.

#import "Basic";
#import "Hash_Table";
#import "jaison";
#import "String";

Server :: struct {
    // `initialized` flips true after the client sends the `initialized`
    // notification. Some methods are only legal after that point.
    initialized: bool;

    // `shutdown_received` flips true once the client sends `shutdown`. The
    // server keeps running and serves no further requests; it only waits for
    // the matching `exit` notification before terminating.
    shutdown_received: bool;

    // `running` is checked by main's read loop. Set to false by `exit`.
    running: bool = true;

    // Exit code main returns to the OS. Per LSP, an `exit` that arrives
    // BEFORE a `shutdown` is a protocol error and we return 1; a clean
    // shutdown+exit sequence returns 0.
    exit_code: int = 0;

    // Position encoding agreed during initialize. Defaults to UTF-16 because
    // that is the LSP default; flipped to UTF-8 if the client advertises it
    // (avoids per-character UTF-16 conversion).
    position_encoding: Position_Encoding = .UTF_16;

    // Open documents keyed by URI. Mutated by didOpen/didChange/didClose;
    // read by hover (and later by semantic tokens, symbols, etc.).
    docs: Document_Store;

    // Workspace-wide symbol index. Populated lazily on the `initialized`
    // notification (so position encoding negotiation has already happened)
    // and kept in sync with open documents via didOpen/didChange/didClose.
    workspace: Workspace;
}

handle_message :: (server: *Server, body: string) {
    success, envelope := json_parse_string(body);
    if !success {
        log_error("Server: failed to parse JSON body: %", body);
        // We can't send a proper error response — id is unknown — so just drop.
        return;
    }
    if envelope.type != .OBJECT {
        log_error("Server: top-level JSON is not an object");
        return;
    }

    obj := envelope.object;

    // Extract method (required).
    method_found, method_val := table_find(obj, "method");
    if !method_found || method_val.type != .STRING {
        log_error("Server: message missing `method` field");
        return;
    }
    method := method_val.str;

    // Extract id (optional → notification when absent).
    id_found, id_val := table_find(obj, "id");
    id: *JSON_Value;
    if id_found {
        // table_find returns by value; we need a pointer that outlives this
        // call. Stash a copy on temp storage.
        copy := cast(*JSON_Value) talloc(size_of(JSON_Value));
        copy.* = id_val;
        id = copy;
    }

    if id {
        log("Server: ← request  method=% id=...", method);
    } else {
        log("Server: ← notify   method=%", method);
    }

    // Dispatch. `params` is left in the envelope for handlers that need it.
    if method == {
        case "initialize";              handle_initialize(server, id, obj);
        case "initialized";             handle_initialized(server);
        case "shutdown";                handle_shutdown(server, id);
        case "exit";                    handle_exit(server);
        case "textDocument/didOpen";              handle_did_open(server, obj);
        case "textDocument/didChange";            handle_did_change(server, obj);
        case "textDocument/didClose";             handle_did_close(server, obj);
        case "textDocument/didSave";              handle_did_save(server, obj);
        case "textDocument/hover";                handle_hover(server, id, obj);
        case "textDocument/semanticTokens/full";  handle_semantic_tokens_full(server, id, obj);
        case "textDocument/documentSymbol";       handle_document_symbol(server, id, obj);
        case "textDocument/definition";           handle_definition(server, id, obj);
        case "textDocument/references";           handle_references(server, id, obj);
        case "textDocument/completion";           handle_completion(server, id, obj);
        case "textDocument/signatureHelp";        handle_signature_help(server, id, obj);
        case "textDocument/foldingRange";         handle_folding_range(server, id, obj);
        case "workspace/symbol";                  handle_workspace_symbol(server, id, obj);
        case "workspace/didChangeWatchedFiles";   handle_did_change_watched_files(server, obj);
        case;
            if id {
                send_error(id, ERROR_METHOD_NOT_FOUND, tprint("Method not found: %", method));
            } else {
                log("Server: unhandled notification: %", method);
            }
    }
}

// --- Handlers ---------------------------------------------------------------

handle_initialize :: (server: *Server, id: *JSON_Value, envelope_obj: *JSON_Object) {
    if !id {
        log_error("Server: `initialize` arrived as a notification (no id) — protocol error");
        return;
    }

    // Negotiate positionEncoding. The client lists its supported encodings
    // at `params.capabilities.general.positionEncodings`; we prefer "utf-8"
    // if offered, because it spares us the per-character UTF-16 conversion
    // for every Position we receive.
    server.position_encoding = .UTF_16;  // spec default
    params_obj, _ := jv_object(envelope_obj, "params");
    if params_obj {
        caps_obj, _ := jv_object(params_obj, "capabilities");
        if caps_obj {
            general_obj, _ := jv_object(caps_obj, "general");
            if general_obj {
                encs, _ := jv_array(general_obj, "positionEncodings");
                for encs {
                    if it.type == .STRING && it.str == "utf-8" {
                        server.position_encoding = .UTF_8;
                        break;
                    }
                }
            }
        }
    }

    // Resolve a workspace root. Prefer workspaceFolders[0]; fall back to
    // rootUri (deprecated but still common from older clients).
    root_path := "";
    if params_obj {
        folders, _ := jv_array(params_obj, "workspaceFolders");
        if folders.count > 0 && folders[0].type == .OBJECT {
            wuri, ok := jv_string(folders[0].object, "uri");
            if ok root_path = path_from_uri(wuri);
        }
        if !root_path.count {
            root_uri, _ := jv_string(params_obj, "rootUri");
            if root_uri.count root_path = path_from_uri(root_uri);
        }
    }
    workspace_set_root(*server.workspace, root_path, server.position_encoding);

    result: Initialize_Result;
    result.capabilities.positionEncoding = ifx server.position_encoding == .UTF_8 then "utf-8" else "utf-16";
    result.capabilities.semanticTokensProvider.legend.tokenTypes     = SEMANTIC_TOKEN_TYPES;
    result.capabilities.semanticTokensProvider.legend.tokenModifiers = SEMANTIC_TOKEN_MODIFIERS;
    payload := json_write_string(result, indent_char = "");
    send_result(id, payload);

    log("Server: negotiated positionEncoding=%", result.capabilities.positionEncoding);
}

handle_initialized :: (server: *Server) {
    server.initialized = true;
    log("Server: client signalled `initialized` — handshake complete");

    // Now that encoding negotiation has settled, scan the workspace.
    // This blocks the loop briefly; for a Jai-sized project it's fast.
    // Future: hand this to a worker thread so we don't stall message
    // processing on huge repos.
    workspace_scan(*server.workspace);
}

handle_shutdown :: (server: *Server, id: *JSON_Value) {
    server.shutdown_received = true;

    // Per spec, the response result for shutdown is null.
    if id send_result(id, "null");
    log("Server: shutdown acknowledged; awaiting `exit`");
}

handle_exit :: (server: *Server) {
    if !server.shutdown_received {
        // `exit` before `shutdown` is a protocol error; spec asks us to
        // exit with code 1 in that case.
        log_error("Server: `exit` received without prior `shutdown` — exiting with code 1");
        server.exit_code = 1;
    } else {
        server.exit_code = 0;
    }
    server.running = false;
}

// --- Text document sync -----------------------------------------------------

handle_did_open :: (server: *Server, envelope_obj: *JSON_Object) {
    params_obj, _    := jv_object(envelope_obj, "params");
    if !params_obj { log_error("didOpen: missing params"); return; }
    td_obj,     _    := jv_object(params_obj, "textDocument");
    if !td_obj     { log_error("didOpen: missing textDocument"); return; }

    uri, uri_ok      := jv_string(td_obj, "uri");
    version, _       := jv_int(td_obj, "version");
    text, _          := jv_string(td_obj, "text");
    if !uri_ok     { log_error("didOpen: missing uri"); return; }

    store_open(*server.docs, uri, version, text);
    log("Server: didOpen % (v%, % bytes)", uri, version, text.count);
    // Open buffer is now authoritative for this URI — replace whatever the
    // disk scan saw with the live text.
    workspace_index_uri(*server.workspace, uri, text);
    publish_diagnostics(server, uri);
}

handle_did_change :: (server: *Server, envelope_obj: *JSON_Object) {
    params_obj, _    := jv_object(envelope_obj, "params");
    if !params_obj { log_error("didChange: missing params"); return; }
    td_obj,     _    := jv_object(params_obj, "textDocument");
    if !td_obj     { log_error("didChange: missing textDocument"); return; }

    uri,     uri_ok  := jv_string(td_obj, "uri");
    version, _       := jv_int(td_obj, "version");
    if !uri_ok     { log_error("didChange: missing uri"); return; }

    // Full sync: take the *last* contentChange's `text` field as the new
    // document body. (Incremental sync would walk every change in order;
    // we'll switch when M2+ benchmarks demand it.)
    changes, _       := jv_array(params_obj, "contentChanges");
    if !changes.count { log_error("didChange: empty contentChanges for %", uri); return; }
    last := changes[changes.count - 1];
    if last.type != .OBJECT { log_error("didChange: contentChange not an object"); return; }

    text_ok, text_val := table_find(last.object, "text");
    if !text_ok || text_val.type != .STRING {
        log_error("didChange: contentChange missing `text` (only full-document sync is supported)");
        return;
    }

    if store_change(*server.docs, uri, version, text_val.str) {
        log("Server: didChange % (v%, % bytes)", uri, version, text_val.str.count);
        workspace_index_uri(*server.workspace, uri, text_val.str);
        publish_diagnostics(server, uri);
    }
}

handle_did_close :: (server: *Server, envelope_obj: *JSON_Object) {
    params_obj, _    := jv_object(envelope_obj, "params");
    if !params_obj { log_error("didClose: missing params"); return; }
    td_obj,     _    := jv_object(params_obj, "textDocument");
    if !td_obj     { log_error("didClose: missing textDocument"); return; }

    uri, uri_ok      := jv_string(td_obj, "uri");
    if !uri_ok     { log_error("didClose: missing uri"); return; }

    store_close(*server.docs, uri);
    log("Server: didClose %", uri);
    // Disk version is authoritative again — re-read it. If the file was
    // never on disk (untitled buffer), this just drops our entries.
    workspace_reindex_from_disk(*server.workspace, uri);
}

handle_did_save :: (server: *Server, envelope_obj: *JSON_Object) {
    params_obj, _ := jv_object(envelope_obj, "params");
    if !params_obj return;
    td_obj,     _ := jv_object(params_obj, "textDocument");
    if !td_obj return;
    uri, uri_ok   := jv_string(td_obj, "uri");
    if !uri_ok return;

    log("Server: didSave % — running compiler check", uri);

    path := path_from_uri(uri);
    if !path.count return;

    doc := store_get(*server.docs, uri);
    doc_text := ifx doc then doc.text else "";

    // Type-check pass via subprocess. Blocks the loop until it returns.
    // Diagnostics for THIS file are sent unconditionally — empty array
    // clears any prior errors from the previous save. doc_text is used to
    // widen diagnostic ranges over the offending token.
    diags := run_check(path, doc_text, server.position_encoding);

    version := ifx doc then doc.version else 0;
    params := Publish_Diagnostics_Params.{
        uri         = uri,
        version     = version,
        diagnostics = diags,
    };
    send_notification("textDocument/publishDiagnostics", json_write_string(params, indent_char = ""));
}

// --- Hover (stub: echoes the identifier under the cursor) -------------------

handle_hover :: (server: *Server, id: *JSON_Value, envelope_obj: *JSON_Object) {
    if !id {
        log_error("hover: arrived without id");
        return;
    }

    params_obj, _    := jv_object(envelope_obj, "params");
    if !params_obj { send_result(id, "null"); return; }
    td_obj,     _    := jv_object(params_obj, "textDocument");
    if !td_obj     { send_result(id, "null"); return; }
    pos_obj,    _    := jv_object(params_obj, "position");
    if !pos_obj    { send_result(id, "null"); return; }

    uri, uri_ok      := jv_string(td_obj, "uri");
    if !uri_ok     { send_result(id, "null"); return; }
    line, _          := jv_int(pos_obj, "line");
    character, _     := jv_int(pos_obj, "character");

    doc := store_get(*server.docs, uri);
    if !doc {
        log_error("hover: unknown document %", uri);
        send_result(id, "null");
        return;
    }

    word := word_at_position(doc, line, character, server.position_encoding);
    if !word.count { send_result(id, "null"); return; }

    hover := Hover_Result.{ contents = tprint("`%`", word) };
    send_result(id, json_write_string(hover, indent_char = ""));
}

// Return the identifier the cursor sits on (or just past), or empty string
// if there isn't one. Shared by hover, definition, and (later) completion's
// prefix detection.
word_at_position :: (doc: *Document, line: int, character: int, encoding: Position_Encoding) -> string {
    cursor := position_to_byte_offset(doc, line, character, encoding);
    if cursor < 0 || cursor > doc.text.count return "";

    start := cursor;
    while start > 0 && is_ident_continue(doc.text[start - 1]) start -= 1;
    end := cursor;
    while end < doc.text.count && is_ident_continue(doc.text[end]) end += 1;
    if end <= start return "";

    s: string;
    s.data  = doc.text.data + start;
    s.count = end - start;
    return s;
}

// --- Semantic tokens --------------------------------------------------------

handle_semantic_tokens_full :: (server: *Server, id: *JSON_Value, envelope_obj: *JSON_Object) {
    if !id return;

    params_obj, _ := jv_object(envelope_obj, "params");
    if !params_obj { send_result(id, "null"); return; }
    td_obj,     _ := jv_object(params_obj, "textDocument");
    if !td_obj    { send_result(id, "null"); return; }
    uri, uri_ok   := jv_string(td_obj, "uri");
    if !uri_ok    { send_result(id, "null"); return; }

    doc := store_get(*server.docs, uri);
    if !doc       { send_result(id, "null"); return; }

    data, _ := analyze_document(doc, server.position_encoding);
    payload := Semantic_Tokens.{ data = data };
    send_result(id, json_write_string(payload, indent_char = ""));
}

// --- Definition ------------------------------------------------------------

handle_definition :: (server: *Server, id: *JSON_Value, envelope_obj: *JSON_Object) {
    if !id return;

    params_obj, _ := jv_object(envelope_obj, "params");
    if !params_obj { send_result(id, "null"); return; }
    td_obj,     _ := jv_object(params_obj, "textDocument");
    if !td_obj    { send_result(id, "null"); return; }
    pos_obj,    _ := jv_object(params_obj, "position");
    if !pos_obj   { send_result(id, "null"); return; }

    uri, uri_ok   := jv_string(td_obj, "uri");
    line, _       := jv_int(pos_obj, "line");
    character, _  := jv_int(pos_obj, "character");
    if !uri_ok    { send_result(id, "null"); return; }

    doc := store_get(*server.docs, uri);
    if !doc       { send_result(id, "null"); return; }

    word := word_at_position(doc, line, character, server.position_encoding);
    if !word.count { send_result(id, "null"); return; }

    matches := workspace_find(*server.workspace, word);
    if !matches.count { send_result(id, "null"); return; }

    // LSP: definition can return a Location, a Location[], or a
    // LocationLink[]. We send Location[] — the most permissive option.
    locations: [..] Location;
    locations.allocator = temp;
    for matches {
        array_add(*locations, Location.{ uri = it.uri, range = it.range });
    }
    send_result(id, json_write_string(locations, indent_char = ""));
}

// --- Signature help --------------------------------------------------------
//
// LSP method: textDocument/signatureHelp. The client fires it when the user
// types `(` or `,` inside a call. We:
//   1. Find the enclosing open paren and the identifier before it (the
//      function being called), plus the parameter index (depth-0 commas
//      between the open paren and the cursor).
//   2. Look up that identifier in the workspace symbol index.
//   3. For each defining file, lex it and extract the signature literal
//      via analysis.extract_signatures.
//   4. Bundle into a Signature_Help with the right activeParameter.

handle_signature_help :: (server: *Server, id: *JSON_Value, envelope_obj: *JSON_Object) {
    if !id return;

    params_obj, _ := jv_object(envelope_obj, "params");
    if !params_obj { send_result(id, "null"); return; }
    td_obj,     _ := jv_object(params_obj, "textDocument");
    pos_obj,    _ := jv_object(params_obj, "position");
    if !td_obj || !pos_obj { send_result(id, "null"); return; }

    uri, uri_ok   := jv_string(td_obj, "uri");
    line, _       := jv_int(pos_obj, "line");
    character, _  := jv_int(pos_obj, "character");
    if !uri_ok { send_result(id, "null"); return; }

    doc := store_get(*server.docs, uri);
    if !doc { send_result(id, "null"); return; }

    cursor_byte := position_to_byte_offset(doc, line, character, server.position_encoding);
    if cursor_byte < 0 { send_result(id, "null"); return; }

    name, param_index, ok := find_call_context(doc.text, cursor_byte);
    if !ok || !name.count { send_result(id, "null"); return; }

    // Where is this name defined? Check the current doc first (local defs
    // take priority), then the workspace index.
    signatures: [..] Signature_Information;
    signatures.allocator = temp;

    collect_signatures_from_text(doc.text, name, *signatures);

    matches := workspace_find(*server.workspace, name);
    for m: matches {
        if m.uri == doc.uri continue;   // already scanned the open buffer
        text := text_for_uri(server, m.uri);
        if !text.count continue;
        collect_signatures_from_text(text, name, *signatures);
    }

    if !signatures.count { send_result(id, "null"); return; }

    result := Signature_Help.{
        signatures      = signatures,
        activeSignature = 0,
        activeParameter = param_index,
    };
    send_result(id, json_write_string(result, indent_char = ""));
}

#scope_file

collect_signatures_from_text :: (text: string, name: string, out: *[..] Signature_Information) {
    extracted := extract_signatures(text, name);
    for sig: extracted {
        params: [..] Parameter_Information;
        params.allocator = temp;
        for r: sig.param_ranges {
            // Drop empty/whitespace-only params (e.g., from `foo()`).
            if r[1] <= r[0] continue;
            substr: string;
            substr.data  = sig.label.data + r[0];
            substr.count = r[1] - r[0];
            substr = trim(substr);
            if !substr.count continue;
            array_add(*params, Parameter_Information.{ label = .[r[0], r[1]] });
        }
        info := Signature_Information.{
            label      = sig.label,
            parameters = params,
        };
        array_add(out, info);
    }
}

text_for_uri :: (server: *Server, uri: string) -> string {
    // Prefer the open buffer; fall back to disk.
    doc := store_get(*server.docs, uri);
    if doc return doc.text;
    path := path_from_uri(uri);
    if !path.count return "";
    text, ok := read_entire_file(path);
    if !ok return "";
    // Owned by the temp allocator? No — read_entire_file uses
    // context.allocator. Copy onto temp so it doesn't leak.
    s := copy_string(text,, temp);
    free(text);
    return s;
}

// Walk tokens backward from `cursor_byte` to find the enclosing call: the
// `(` we're inside and the identifier before it. Returns (name, param_index,
// true) or ("", 0, false) if the cursor isn't inside a call.
find_call_context :: (text: string, cursor_byte: int) -> name: string, param_index: int, ok: bool {
    snaps := lex_to_snaps(text);
    if !snaps.count return "", 0, false;
    line_starts := compute_line_starts(text);

    // Index of the last token whose end is <= cursor_byte. We walk backward
    // starting from there.
    last_idx := -1;
    for i: 0..snaps.count - 1 {
        end_byte := snap_to_byte(snaps[i].l1, snaps[i].c1, line_starts);
        if end_byte > cursor_byte break;
        last_idx = i;
    }
    if last_idx < 0 return "", 0, false;

    LPAREN :: cast(Token_Type) #char "(";
    RPAREN :: cast(Token_Type) #char ")";
    LBRACE :: cast(Token_Type) #char "{";
    RBRACE :: cast(Token_Type) #char "}";
    SEMI   :: cast(Token_Type) #char ";";
    COMMA  :: cast(Token_Type) #char ",";

    depth     := 0;
    param_idx := 0;
    i := last_idx;
    while i >= 0 {
        t := snaps[i].type;

        // If we cross a brace or semicolon while not inside any nested
        // parens, we're definitely not in a call's args anymore. Bail out
        // — this prevents false positives where the cursor sits after a
        // proc body's `}` but before another statement's `(`.
        if depth == 0 && (t == LBRACE || t == RBRACE || t == SEMI) return "", 0, false;

        if t == RPAREN {
            depth += 1;
        } else if t == LPAREN {
            if depth == 0 {
                // Found it. The token before should be an identifier.
                if i - 1 >= 0 && snaps[i - 1].type == .IDENT {
                    return snaps[i - 1].name, param_idx, true;
                }
                return "", 0, false;
            }
            depth -= 1;
        } else if t == COMMA && depth == 0 {
            param_idx += 1;
        }
        i -= 1;
    }
    return "", 0, false;
}

snap_to_byte :: (line_1based: s32, col_1based: s32, line_starts: [] int) -> int {
    line := cast(int) line_1based - 1;
    col  := cast(int) col_1based  - 1;
    if line < 0 || line >= line_starts.count return 0;
    return line_starts[line] + col;
}

#scope_export

// --- Find all references ---------------------------------------------------

handle_references :: (server: *Server, id: *JSON_Value, envelope_obj: *JSON_Object) {
    if !id return;

    params_obj, _ := jv_object(envelope_obj, "params");
    if !params_obj { send_result(id, "null"); return; }
    td_obj,     _ := jv_object(params_obj, "textDocument");
    pos_obj,    _ := jv_object(params_obj, "position");
    if !td_obj || !pos_obj { send_result(id, "null"); return; }

    uri, uri_ok   := jv_string(td_obj, "uri");
    line, _       := jv_int(pos_obj, "line");
    character, _  := jv_int(pos_obj, "character");
    if !uri_ok { send_result(id, "null"); return; }

    // `context.includeDeclaration` defaults to false per spec, but most
    // clients send true. We honor whichever is sent.
    include_decl := false;
    ctx_obj, _ := jv_object(params_obj, "context");
    if ctx_obj {
        found, v := table_find(ctx_obj, "includeDeclaration");
        if found && v.type == .BOOLEAN include_decl = v.boolean;
    }

    doc := store_get(*server.docs, uri);
    if !doc { send_result(id, "null"); return; }

    target := word_at_position(doc, line, character, server.position_encoding);
    if !target.count { send_result(id, "null"); return; }

    locations: [..] Location;
    locations.allocator = temp;

    // Build the set of URIs to scan: union of workspace-indexed files and
    // currently-open buffers. A `seen` set dedupes (a file can be both
    // indexed on disk AND open in a buffer).
    seen: Table(string, bool);
    seen.allocator = temp;

    // Open buffers first — they're authoritative for their URI.
    for slot, open_uri: server.docs.docs {
        scan_uri_for_target(open_uri, slot.text, target, include_decl, server.position_encoding, *locations);
        table_set(*seen, open_uri, true);
    }

    // Then disk-only files.
    for _, ws_uri: server.workspace.by_uri {
        found, _ := table_find(*seen, ws_uri);
        if found continue;
        path := path_from_uri(ws_uri);
        if !path.count continue;
        text, ok := read_entire_file(path);
        if !ok continue;
        // The text isn't freed — temp will reclaim it when we reset after
        // the response goes out.
        scan_uri_for_target(ws_uri, text, target, include_decl, server.position_encoding, *locations);
    }

    log("Server: references for '%' returned % locations", target, locations.count);
    send_result(id, json_write_string(locations, indent_char = ""));
}

#scope_file

scan_uri_for_target :: (
    uri: string,
    text: string,
    target: string,
    include_decl: bool,
    encoding: Position_Encoding,
    out: *[..] Location,
) {
    occs := find_ident_occurrences(text, target);
    if !occs.count return;

    line_starts := compute_line_starts(text);
    defer array_free(line_starts);

    for occ: occs {
        if occ.is_decl && !include_decl continue;
        loc: Location;
        loc.uri = uri;
        loc.range = ident_occurrence_to_range(text, line_starts, occ, encoding);
        array_add(out, loc);
    }
}

ident_occurrence_to_range :: (text: string, line_starts: [] int, occ: Ident_Occurrence, encoding: Position_Encoding) -> Range {
    line0 := cast(int) occ.l0 - 1;
    line1 := cast(int) occ.l1 - 1;
    if line0 < 0 line0 = 0;
    if line1 < line0 line1 = line0;
    col0_bytes := cast(int) occ.c0 - 1;
    col1_bytes := cast(int) occ.c1 - 1;
    if col0_bytes < 0 col0_bytes = 0;
    if col1_bytes < 0 col1_bytes = col0_bytes;
    r: Range;
    r.start.line      = line0;
    r.start.character = byte_col_to_encoding_col(text, line_starts, line0, col0_bytes, encoding);
    r.end.line        = line1;
    r.end.character   = byte_col_to_encoding_col(text, line_starts, line1, col1_bytes, encoding);
    return r;
}

#scope_export

// --- File watcher (external changes to .jai files) -------------------------

FILE_CHANGE_CREATED :: 1;
FILE_CHANGE_CHANGED :: 2;
FILE_CHANGE_DELETED :: 3;

handle_did_change_watched_files :: (server: *Server, envelope_obj: *JSON_Object) {
    params_obj, _ := jv_object(envelope_obj, "params");
    if !params_obj return;
    changes, _ := jv_array(params_obj, "changes");
    if !changes.count return;

    for change: changes {
        if change.type != .OBJECT continue;
        uri, uri_ok := jv_string(change.object, "uri");
        ftype, _    := jv_int(change.object, "type");
        if !uri_ok continue;

        // If the file is open in our buffer store, we already have authoritative
        // text — disk events would just race the in-flight didChange we'll
        // get from the editor. Skip.
        if store_get(*server.docs, uri) {
            log("Watcher: ignoring disk change for open buffer %", uri);
            continue;
        }

        if ftype == FILE_CHANGE_DELETED {
            workspace_purge_uri(*server.workspace, uri);
            log("Watcher: purged %", uri);
        } else {
            // Created or Changed — reindex from disk.
            workspace_reindex_from_disk(*server.workspace, uri);
            log("Watcher: reindexed % (type=%)", uri, ftype);
        }
    }
}

// --- Workspace symbol search -----------------------------------------------

WORKSPACE_SYMBOL_LIMIT :: 200;

handle_workspace_symbol :: (server: *Server, id: *JSON_Value, envelope_obj: *JSON_Object) {
    if !id return;

    params_obj, _ := jv_object(envelope_obj, "params");
    query, _      := jv_string(params_obj, "query");

    results: [..] LSP_Workspace_Symbol;
    results.allocator = temp;

    // Walk the workspace index, keep entries whose name contains `query`
    // (case-insensitive substring; VSCode's ⌘T further refines client-side).
    // Empty query → return everything up to the cap.
    for slot, name: server.workspace.by_name {
        if results.count >= WORKSPACE_SYMBOL_LIMIT break;
        if query.count && !name_matches_query(name, query) continue;

        for sym: slot {
            if results.count >= WORKSPACE_SYMBOL_LIMIT break;
            array_add(*results, LSP_Workspace_Symbol.{
                name     = sym.name,
                kind     = cast(int) sym.kind,
                location = .{ uri = sym.uri, range = sym.range },
            });
        }
    }

    send_result(id, json_write_string(results, indent_char = ""));
}

// --- Folding ranges --------------------------------------------------------

handle_folding_range :: (server: *Server, id: *JSON_Value, envelope_obj: *JSON_Object) {
    if !id return;

    params_obj, _ := jv_object(envelope_obj, "params");
    if !params_obj { send_result(id, "null"); return; }
    td_obj,     _ := jv_object(params_obj, "textDocument");
    if !td_obj    { send_result(id, "null"); return; }
    uri, uri_ok   := jv_string(td_obj, "uri");
    if !uri_ok    { send_result(id, "null"); return; }

    doc := store_get(*server.docs, uri);
    if !doc       { send_result(id, "null"); return; }

    ranges := compute_folding_ranges(doc.text);
    send_result(id, json_write_string(ranges, indent_char = ""));
}

// --- Completion ------------------------------------------------------------

handle_completion :: (server: *Server, id: *JSON_Value, envelope_obj: *JSON_Object) {
    if !id return;

    // M4 completion is context-free: we return everything in the workspace
    // index plus the Jai keyword set. The client filters by the in-progress
    // word. Once we have a parser, we can scope the list to the cursor's
    // surroundings.

    items: [..] Completion_Item;
    items.allocator = temp;

    // Workspace symbols.
    for slot, name: server.workspace.by_name {
        if !slot.count continue;
        first := slot[0];
        array_add(*items, Completion_Item.{
            label  = name,
            kind   = cast(int) symbol_kind_to_completion_kind(first.kind),
            detail = first.detail,
        });
    }

    // Jai keywords.
    for kw: JAI_KEYWORDS {
        array_add(*items, Completion_Item.{
            label  = kw,
            kind   = cast(int) Completion_Item_Kind.KEYWORD,
            detail = "keyword",
        });
    }

    list := Completion_List.{ items = items };
    send_result(id, json_write_string(list, indent_char = ""));
}

handle_document_symbol :: (server: *Server, id: *JSON_Value, envelope_obj: *JSON_Object) {
    if !id return;

    params_obj, _ := jv_object(envelope_obj, "params");
    if !params_obj { send_result(id, "null"); return; }
    td_obj,     _ := jv_object(params_obj, "textDocument");
    if !td_obj    { send_result(id, "null"); return; }
    uri, uri_ok   := jv_string(td_obj, "uri");
    if !uri_ok    { send_result(id, "null"); return; }

    doc := store_get(*server.docs, uri);
    if !doc       { send_result(id, "null"); return; }

    symbols := collect_document_symbols(doc, server.position_encoding);

    // Serialize the array directly — LSP accepts either DocumentSymbol[] or
    // the legacy SymbolInformation[] at this position; we send the modern
    // (hierarchical) form, even though M3 only emits a flat list.
    send_result(id, json_write_string(symbols, indent_char = ""));
}

// --- Diagnostics ------------------------------------------------------------

publish_diagnostics :: (server: *Server, uri: string) {
    doc := store_get(*server.docs, uri);
    if !doc return;

    _, diags := analyze_document(doc, server.position_encoding);

    params := Publish_Diagnostics_Params.{
        uri         = uri,
        version     = doc.version,
        diagnostics = diags,
    };
    send_notification("textDocument/publishDiagnostics", json_write_string(params, indent_char = ""));
}

// Send a JSON-RPC notification (no id, no response expected).
send_notification :: (method: string, params_json: string) {
    builder: String_Builder;
    builder.allocator = temp;

    append(*builder, #string END
{"jsonrpc":"2.0","method":
END);
    append(*builder, tprint("\"%\"", method));
    append(*builder, #string END
,"params":
END);
    append(*builder, params_json);
    append(*builder, "}");

    body := builder_to_string(*builder,, temp);
    write_message(body);
    log("Server: → notify   method=% (% bytes)", method, body.count);
}

// --- Wire helpers -----------------------------------------------------------
//
// We compose the response envelope by hand so we can guarantee that exactly
// one of `result` / `error` is present (jaison would emit the absent one as
// `null`).

send_result :: (id: *JSON_Value, result_json: string) {
    builder: String_Builder;
    builder.allocator = temp;

    append(*builder, #string END
{"jsonrpc":"2.0","id":
END);
    write_id(*builder, id);
    append(*builder, #string END
,"result":
END);
    append(*builder, result_json);
    append(*builder, "}");

    body := builder_to_string(*builder,, temp);
    write_message(body);
    log("Server: → response (result, % bytes)", body.count);
}

send_error :: (id: *JSON_Value, code: int, message: string) {
    builder: String_Builder;
    builder.allocator = temp;

    append(*builder, #string END
{"jsonrpc":"2.0","id":
END);
    write_id(*builder, id);
    append(*builder, #string END
,"error":
END);
    err := Response_Error.{ code = code, message = message };
    append(*builder, json_write_string(err, indent_char = ""));
    append(*builder, "}");

    body := builder_to_string(*builder,, temp);
    write_message(body);
    log("Server: → response (error code=%, %)", code, message);
}

#scope_file

// JSON-RPC ids may be number or string (or null). Echo whatever we got back
// verbatim. If the envelope had no id at all we shouldn't have called into
// here — but defensively write `null` rather than corrupt the frame.
write_id :: (builder: *String_Builder, id: *JSON_Value) {
    if !id {
        append(builder, "null");
        return;
    }
    json_write_json_value(builder, id.*, indent_char = "");
}

// --- JSON_Value lookup helpers ---------------------------------------------
//
// Handlers walk request `params` as generic JSON_Value trees (cheaper than
// declaring a typed struct per method and re-serializing the params subtree
// to feed jaison's typed parser). These tiny accessors return (value, ok)
// so handlers can branch cleanly on missing/wrong-typed fields.

jv_object :: (parent: *JSON_Object, key: string) -> *JSON_Object, bool {
    if !parent return null, false;
    found, v := table_find(parent, key);
    if !found || v.type != .OBJECT return null, false;
    return v.object, true;
}

jv_string :: (parent: *JSON_Object, key: string) -> string, bool {
    if !parent return "", false;
    found, v := table_find(parent, key);
    if !found || v.type != .STRING return "", false;
    return v.str, true;
}

jv_int :: (parent: *JSON_Object, key: string) -> int, bool {
    if !parent return 0, false;
    found, v := table_find(parent, key);
    if !found || v.type != .NUMBER return 0, false;
    return cast(int) v.number, true;
}

jv_array :: (parent: *JSON_Object, key: string) -> [] JSON_Value, bool {
    empty: [] JSON_Value;
    if !parent return empty, false;
    found, v := table_find(parent, key);
    if !found || v.type != .ARRAY return empty, false;
    return v.array, true;
}

// Jai identifier continue: ASCII letter, digit, or underscore.
// Identifiers can't start with a digit, but for "what's under the cursor"
// purposes we don't care — we let the walk-back find the leftmost extent.
is_ident_continue :: (b: u8) -> bool {
    if b == #char "_"                   return true;
    if b >= #char "0" && b <= #char "9" return true;
    if b >= #char "A" && b <= #char "Z" return true;
    if b >= #char "a" && b <= #char "z" return true;
    return false;
}

// Map our internal Symbol_Kind to the LSP CompletionItemKind enum.
// CompletionItemKind has its own numbering distinct from SymbolKind.
symbol_kind_to_completion_kind :: (k: Symbol_Kind) -> Completion_Item_Kind {
    if k == .FUNCTION return .FUNCTION;
    if k == .STRUCT   return .STRUCT;
    if k == .ENUM     return .ENUM;
    if k == .CONSTANT return .CONSTANT;
    if k == .VARIABLE return .VARIABLE;
    return .VARIABLE;
}

// Case-insensitive substring match for workspace/symbol query.
name_matches_query :: (name: string, query: string) -> bool {
    if query.count > name.count return false;
    i := 0;
    while i <= name.count - query.count {
        match := true;
        for j: 0..query.count - 1 {
            a := name[i + j];
            b := query[j];
            if a >= #char "A" && a <= #char "Z" a += 32;
            if b >= #char "A" && b <= #char "Z" b += 32;
            if a != b { match = false; break; }
        }
        if match return true;
        i += 1;
    }
    return false;
}

// Jai language keywords. Hardcoded rather than reflected off the lexer's
// KEYWORD_* enum because the wire-facing spelling (lowercase, no prefix)
// doesn't survive direct conversion of the enum members.
JAI_KEYWORDS :: string.[
    "if", "ifx", "then", "else", "case", "for", "while", "break", "continue",
    "return", "defer", "remove", "using",
    "struct", "enum", "enum_flags", "union", "interface", "operator",
    "inline", "no_inline", "cast", "xx",
    "context", "push_context",
    "size_of", "type_of", "code_of", "initializer_of", "type_info", "is_constant",
    "null", "true", "false",
];
