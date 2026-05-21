// Workspace-wide symbol index, scanned from disk and refreshed live.
//
// Design:
//   * On `initialized`, walk the workspace root for *.jai files and index
//     each one's top-level declarations.
//   * On didOpen/didChange, re-index from the open buffer's text — open
//     documents are authoritative; their on-disk version is ignored.
//   * On didClose, re-index from disk so we don't keep a stale buffer view.
//
// Storage:
//   * `by_name`: name -> [..] Workspace_Symbol, supports definition lookup.
//   * `by_uri`:  uri  -> [..] string (names defined there), so refreshes can
//     surgically drop the file's prior contributions before re-adding.
//
// All workspace memory lives on context.allocator (heap). Names and URIs are
// owned copies; nothing borrows from caller buffers.

#import "Basic";
#import "File";
#import "File_Utilities";
#import "Hash_Table";
#import "String";

Workspace_Symbol :: struct {
    name:   string;
    detail: string;
    kind:   Symbol_Kind;
    uri:    string;
    range:  Range;        // identifier range, in negotiated encoding
}

Workspace :: struct {
    root_path:   string;             // absolute filesystem path; "" if no root
    encoding:    Position_Encoding;  // pinned from initialize negotiation
    by_name:     Table(string, [..] Workspace_Symbol);
    by_uri:      Table(string, [..] string);
    scanned:     bool;
}

// --- Lifecycle --------------------------------------------------------------

workspace_set_root :: (ws: *Workspace, root_path: string, encoding: Position_Encoding) {
    ws.root_path = copy_string(root_path);
    ws.encoding  = encoding;
}

workspace_scan :: (ws: *Workspace) {
    if !ws.root_path.count {
        log("Workspace: no root configured, skipping scan");
        ws.scanned = true;
        return;
    }
    log("Workspace: scanning %", ws.root_path);

    visitor_data: Visitor_Data;
    visitor_data.ws = ws;
    visit_files(ws.root_path, true, *visitor_data, visit_jai_file);

    log("Workspace: scan complete, % files indexed, % distinct names", visitor_data.file_count, ws.by_name.count);
    ws.scanned = true;
}

// Index a single file from text in memory. Replaces any prior entries for
// the same URI. Used both during the disk scan and for open-buffer refreshes.
workspace_index_uri :: (ws: *Workspace, uri: string, text: string) {
    // Drop the prior contributions for this URI, if any.
    workspace_purge_uri(ws, uri);

    decls := find_top_level_decls(text);
    if !decls.count return;

    // Build a line-start index for position math. Lives on temp; we copy
    // only the converted Range into the long-lived store.
    line_starts := compute_line_starts(text);
    defer array_free(line_starts);

    uri_copy := copy_string(uri);
    names_for_uri: [..] string;

    for d: decls {
        range := decl_to_range(text, line_starts, d, ws.encoding);
        sym: Workspace_Symbol;
        sym.name   = copy_string(d.name);
        sym.detail = d.detail;       // detail strings are static literals — no copy needed
        sym.kind   = d.kind;
        sym.uri    = uri_copy;
        sym.range  = range;

        slot := table_find_pointer(*ws.by_name, sym.name);
        if !slot {
            list: [..] Workspace_Symbol;
            array_add(*list, sym);
            table_set(*ws.by_name, sym.name, list);
        } else {
            array_add(slot, sym);
        }
        array_add(*names_for_uri, sym.name);
    }
    table_set(*ws.by_uri, uri_copy, names_for_uri);
}

// Re-read the file from disk and re-index it. No-op if read fails.
workspace_reindex_from_disk :: (ws: *Workspace, uri: string) {
    path := path_from_uri(uri);
    if !path.count return;
    text, ok := read_entire_file(path);
    if !ok {
        // File may have been deleted — just drop our entries for it.
        workspace_purge_uri(ws, uri);
        return;
    }
    defer free(text);
    workspace_index_uri(ws, uri, text);
}

// Drop all symbol entries that came from `uri`. Used before re-indexing the
// same URI, and on file deletion.
workspace_purge_uri :: (ws: *Workspace, uri: string) {
    found, names := table_find(*ws.by_uri, uri);
    if !found return;

    for name: names {
        slot := table_find_pointer(*ws.by_name, name);
        if !slot continue;
        // Remove every entry that came from this URI. There can be more
        // than one (e.g. shadowed names) — wipe them all.
        new_list: [..] Workspace_Symbol;
        for slot.* {
            if it.uri != uri array_add(*new_list, it);
        }
        if new_list.count == 0 {
            array_free(slot.*);
            table_remove(*ws.by_name, name);
        } else {
            array_free(slot.*);
            slot.* = new_list;
        }
    }
    array_free(names);
    table_remove(*ws.by_uri, uri);
}

// --- Lookup -----------------------------------------------------------------

workspace_find :: (ws: *Workspace, name: string) -> [] Workspace_Symbol {
    found, list := table_find(*ws.by_name, name);
    if !found {
        empty: [] Workspace_Symbol;
        return empty;
    }
    return list;
}

// --- URI <-> path -----------------------------------------------------------
//
// Minimal helpers: we handle "file://" URIs with optional percent-encoded
// bytes. Authority, query, and fragment are not supported (LSP URIs in
// practice are bare file URIs).

path_from_uri :: (uri: string) -> string {
    PREFIX :: "file://";
    if !begins_with(uri, PREFIX) return "";
    rest := slice(uri, PREFIX.count, uri.count - PREFIX.count);

    builder: String_Builder;
    builder.allocator = temp;
    i := 0;
    while i < rest.count {
        c := rest[i];
        if c == #char "%" && i + 2 < rest.count {
            high := hex_value(rest[i+1]);
            low  := hex_value(rest[i+2]);
            if high >= 0 && low >= 0 {
                append(*builder, cast(u8) (high * 16 + low));
                i += 3;
                continue;
            }
        }
        append(*builder, c);
        i += 1;
    }
    return builder_to_string(*builder,, temp);
}

uri_from_path :: (path: string) -> string {
    // Conservative encoder: percent-encode anything outside the unreserved
    // set + "/". Enough for filesystem paths LSP cares about.
    builder: String_Builder;
    builder.allocator = temp;
    append(*builder, "file://");
    for i: 0..path.count - 1 {
        c := path[i];
        if is_uri_safe(c) {
            append(*builder, c);
        } else {
            append(*builder, #char "%");
            append(*builder, hex_digit(c >> 4));
            append(*builder, hex_digit(c & 0xF));
        }
    }
    return builder_to_string(*builder,, temp);
}

#scope_file

Visitor_Data :: struct {
    ws:         *Workspace;
    file_count: int;
}

visit_jai_file :: (info: *File_Visit_Info, vdata: *Visitor_Data) {
    if info.is_directory return;
    if !ends_with(info.short_name, ".jai") return;

    text, ok := read_entire_file(info.full_name);
    if !ok return;
    defer free(text);

    uri := uri_from_path(info.full_name);
    workspace_index_uri(vdata.ws, uri, text);
    vdata.file_count += 1;
}

ends_with :: (s: string, suffix: string) -> bool {
    if suffix.count > s.count return false;
    return slice(s, s.count - suffix.count, suffix.count) == suffix;
}

hex_value :: (c: u8) -> int {
    if c >= #char "0" && c <= #char "9" return c - #char "0";
    if c >= #char "a" && c <= #char "f" return 10 + c - #char "a";
    if c >= #char "A" && c <= #char "F" return 10 + c - #char "A";
    return -1;
}

hex_digit :: (n: u8) -> u8 {
    if n < 10 return #char "0" + n;
    return #char "A" + (n - 10);
}

is_uri_safe :: (c: u8) -> bool {
    if c >= #char "a" && c <= #char "z" return true;
    if c >= #char "A" && c <= #char "Z" return true;
    if c >= #char "0" && c <= #char "9" return true;
    if c == #char "/" return true;
    if c == #char "-" return true;
    if c == #char "_" return true;
    if c == #char "." return true;
    if c == #char "~" return true;
    return false;
}
