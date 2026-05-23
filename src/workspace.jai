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
#import "Thread";

Workspace_Symbol :: struct {
    name:   string;
    detail: string;
    kind:   Symbol_Kind;
    uri:    string;
    range:  Range;        // identifier range, in negotiated encoding
}

// Thread-safe workspace symbol index.
//
// Concurrency model:
//   * `mutex` guards by_name, by_uri, and scanned.
//   * The initial workspace_scan runs on a background thread spawned via
//     workspace_scan_async. It calls workspace_index_uri per file, each of
//     which takes the lock briefly.
//   * Main-thread handlers (hover, definition, references, completion,
//     workspace/symbol) lock before reading. workspace_find / workspace_get
//     return values that are safe to use after unlock (strings copied onto
//     the temporary allocator).
//   * didOpen / didChange / didClose / didChangeWatchedFiles also mutate
//     under lock.
Workspace :: struct {
    root_path:   string;             // absolute filesystem path; "" if no root
    encoding:    Position_Encoding;  // pinned from initialize negotiation
    by_name:     Table(string, [..] Workspace_Symbol);
    by_uri:      Table(string, [..] string);
    scanned:     bool;

    mutex:        Mutex;
    scan_thread:  Thread;
    scan_running: bool;
    scan_joined:  bool;        // tracked so thread_deinit fires at most once
}

// --- Lifecycle --------------------------------------------------------------

workspace_set_root :: (ws: *Workspace, root_path: string, encoding: Position_Encoding) {
    ws.root_path = copy_string(root_path);
    ws.encoding  = encoding;
    init(*ws.mutex, "jai-lsp-workspace");
}

// Synchronous scan (used by the worker thread; also fine to call directly
// for single-shot work). Locks per file while updating the index, so other
// threads making lookups stay responsive.
workspace_scan :: (ws: *Workspace) {
    if !ws.root_path.count {
        log("Workspace: no root configured, skipping scan");
        lock(*ws.mutex);
        ws.scanned = true;
        unlock(*ws.mutex);
        return;
    }
    log("Workspace: scanning %", ws.root_path);

    visitor_data: Visitor_Data;
    visitor_data.ws = ws;
    visit_files(ws.root_path, true, *visitor_data, visit_jai_file);

    lock(*ws.mutex);
    distinct := ws.by_name.count;
    ws.scanned = true;
    unlock(*ws.mutex);

    log("Workspace: scan complete, % files indexed, % distinct names", visitor_data.file_count, distinct);
}

// Spawn the scan on a worker thread so the LSP main loop stays responsive.
// Returns immediately. handlers run normally; lookups against by_name see
// whatever's been indexed so far (lock-protected).
workspace_scan_async :: (ws: *Workspace) {
    if ws.scan_running {
        log("Workspace: scan already running, ignoring duplicate request");
        return;
    }
    ws.scan_running = true;
    ok := thread_init(*ws.scan_thread, scan_thread_proc);
    if !ok {
        log_error("Workspace: thread_init failed, falling back to sync scan");
        ws.scan_running = false;
        workspace_scan(ws);
        return;
    }
    ws.scan_thread.data = ws;
    thread_start(*ws.scan_thread);
}

scan_thread_proc :: (thread: *Thread) -> s64 {
    ws := cast(*Workspace) thread.data;
    workspace_scan(ws);
    ws.scan_running = false;
    return 0;
}

// Block until the scan thread finishes. Safe to call multiple times —
// readers (definition, workspace/symbol, completion, ...) call this before
// touching the index so they don't miss late entries. The OS-level cleanup
// (thread_deinit) only happens once, in workspace_join_scan_thread on
// shutdown.
workspace_wait_for_scan :: (ws: *Workspace) {
    if ws.scan_joined return;
    if !ws.scan_running return;
    thread_is_done(*ws.scan_thread, -1);   // -1 = wait indefinitely
}

// One-time thread cleanup. Called on shutdown only.
workspace_join_scan_thread :: (ws: *Workspace) {
    workspace_wait_for_scan(ws);
    if !ws.scan_joined {
        ws.scan_joined = true;
        thread_deinit(*ws.scan_thread);
    }
}

// Index a single file from text in memory. Replaces any prior entries for
// the same URI. Used both during the disk scan and for open-buffer refreshes.
// Acquires the workspace mutex internally.
workspace_index_uri :: (ws: *Workspace, uri: string, text: string) {
    // Lex + position-math OUTSIDE the lock — those are CPU-bound and don't
    // touch shared state. Only the table update needs to be exclusive.
    decls := find_top_level_decls(text);
    if !decls.count {
        lock(*ws.mutex);
        defer unlock(*ws.mutex);
        purge_uri_locked(ws, uri);
        return;
    }
    line_starts := compute_line_starts(text);
    defer array_free(line_starts);

    // Build the symbol list off-lock.
    new_syms: [..] Workspace_Symbol;
    new_syms.allocator = temp;
    for d: decls {
        range := decl_to_range(text, line_starts, d, ws.encoding);
        sym: Workspace_Symbol;
        sym.name   = copy_string(d.name);     // heap-owned; survives temp reset
        sym.detail = d.detail;                // static string literal
        sym.kind   = d.kind;
        sym.range  = range;
        array_add(*new_syms, sym);
    }

    lock(*ws.mutex);
    defer unlock(*ws.mutex);

    purge_uri_locked(ws, uri);

    uri_copy := copy_string(uri);
    names_for_uri: [..] string;
    for * sym: new_syms {
        sym.uri = uri_copy;
        slot := table_find_pointer(*ws.by_name, sym.name);
        if !slot {
            list: [..] Workspace_Symbol;
            array_add(*list, sym.*);
            table_set(*ws.by_name, sym.name, list);
        } else {
            array_add(slot, sym.*);
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
// same URI, and on file deletion. Public; acquires the lock.
workspace_purge_uri :: (ws: *Workspace, uri: string) {
    lock(*ws.mutex);
    defer unlock(*ws.mutex);
    purge_uri_locked(ws, uri);
}

// Internal: same as workspace_purge_uri but caller already holds the lock.
purge_uri_locked :: (ws: *Workspace, uri: string) {
    found, names := table_find(*ws.by_uri, uri);
    if !found return;

    for name: names {
        slot := table_find_pointer(*ws.by_name, name);
        if !slot continue;
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

// Returns a temp-allocated snapshot of the named slot. Strings are also
// copied onto temp so the result remains safe to use after the workspace
// mutex is released. Waits for any in-flight initial scan first so we
// don't return empty just because indexing is still running.
workspace_find :: (ws: *Workspace, name: string) -> [] Workspace_Symbol {
    workspace_wait_for_scan(ws);

    out: [..] Workspace_Symbol;
    out.allocator = temp;

    lock(*ws.mutex);
    defer unlock(*ws.mutex);

    found, list := table_find(*ws.by_name, name);
    if !found return out;

    for list array_add(*out, snapshot_symbol(it));
    return out;
}

// Snapshot ALL workspace symbols (optionally filtered by name predicate),
// returning a temp-allocated list safe to use after unlock. Used by
// workspace/symbol search and completion when the caller needs to iterate
// without holding the lock.
workspace_snapshot_all :: (ws: *Workspace, name_filter: (string) -> bool = null, limit: int = -1) -> [] Workspace_Symbol {
    workspace_wait_for_scan(ws);

    out: [..] Workspace_Symbol;
    out.allocator = temp;

    lock(*ws.mutex);
    defer unlock(*ws.mutex);

    for slot, name: ws.by_name {
        if limit >= 0 && out.count >= limit break;
        if name_filter && !name_filter(name) continue;
        for slot {
            if limit >= 0 && out.count >= limit break;
            array_add(*out, snapshot_symbol(it));
        }
    }
    return out;
}

// Snapshot of all URIs currently in the index. Useful for find-references
// which needs to iterate every indexed file.
workspace_snapshot_uris :: (ws: *Workspace) -> [] string {
    workspace_wait_for_scan(ws);

    out: [..] string;
    out.allocator = temp;

    lock(*ws.mutex);
    defer unlock(*ws.mutex);

    for _, uri: ws.by_uri {
        array_add(*out, copy_string(uri,, temp));
    }
    return out;
}

// Cheap "what kind is this name?" lookup. Used by the semantic-tokens
// pass: for each IDENT not declared locally, we ask "is this a known
// cross-file proc/struct/enum?" Returns the kind of the first matching
// entry plus a found flag.
workspace_lookup_kind :: (ws: *Workspace, name: string) -> Symbol_Kind, bool {
    lock(*ws.mutex);
    defer unlock(*ws.mutex);
    found, list := table_find(*ws.by_name, name);
    if !found || !list.count return .CONSTANT, false;
    return list[0].kind, true;
}

snapshot_symbol :: (sym: Workspace_Symbol) -> Workspace_Symbol {
    out: Workspace_Symbol;
    out.name   = copy_string(sym.name,, temp);
    out.detail = sym.detail;                   // static literal — no copy
    out.kind   = sym.kind;
    out.uri    = copy_string(sym.uri,, temp);
    out.range  = sym.range;
    return out;
}

// --- URI <-> path -----------------------------------------------------------
//
// Minimal helpers: we handle "file://" URIs with optional percent-encoded
// bytes. Authority, query, and fragment are not supported (LSP URIs in
// practice are bare file URIs).

// The public converters bake in the host OS; the `_impl` workers take the
// platform as a parameter so both branches are testable on any build host
// (see the `#run` round-trip test below).
path_from_uri :: (uri:  string) -> string { return path_from_uri_impl(uri,  OS == .WINDOWS); }
uri_from_path :: (path: string) -> string { return uri_from_path_impl(path, OS == .WINDOWS); }

path_from_uri_impl :: (uri: string, windows: bool) -> string {
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
    path := builder_to_string(*builder,, temp);

    if windows {
        // A Windows file URI is `file:///C:/dir/file`. After stripping the
        // `file://` prefix we are left with a spurious leading slash before
        // the drive letter (`/C:/dir/file`); drop it so the result is a real
        // path. Forward slashes are accepted by the Win32 file APIs, so we
        // leave them as-is. Without this every disk operation (compile target,
        // signature-help file reads) silently no-ops on Windows.
        if path.count >= 3 && path[0] == #char "/" && is_drive_letter(path[1]) && path[2] == #char ":" {
            path = slice(path, 1, path.count - 1);
        }
    }

    return path;
}

is_drive_letter :: (c: u8) -> bool {
    return (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z");
}

uri_from_path_impl :: (path: string, windows: bool) -> string {
    // Conservative encoder: percent-encode anything outside the unreserved
    // set + "/". Enough for filesystem paths LSP cares about.
    builder: String_Builder;
    builder.allocator = temp;
    append(*builder, "file://");

    p := path;
    if windows {
        // Drive-letter paths (`C:\dir\file` or `C:/dir/file`) need the third
        // slash so the URI is `file:///C:/dir/file`, matching what clients
        // send. Without it the Locations we emit don't round-trip and
        // go-to-definition lands nowhere.
        if p.count >= 2 && is_drive_letter(p[0]) && p[1] == #char ":" {
            append(*builder, #char "/");
        }
    }

    for i: 0..p.count - 1 {
        c := p[i];
        // On Windows, normalize backslashes to forward slashes rather than
        // percent-encoding them (`%5C`), which clients won't recognize.
        if windows && c == #char "\\" {
            append(*builder, #char "/");
            continue;
        }
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

// Compile-time round-trip test for the URI <-> path converters. Runs on every
// build, on every host, and covers BOTH the Windows and POSIX branches (the
// `windows` arg is explicit, so a Linux CI still validates the Windows logic).
// Regression guard for the Windows drive-letter bug where go-to-definition and
// signature help broke while syntax highlighting kept working.
#run {
    // POSIX: leading slash is part of the path; backslash is a literal byte.
    assert(path_from_uri_impl("file:///home/u/a.jai", false) == "/home/u/a.jai");
    assert(uri_from_path_impl("/home/u/a.jai", false)        == "file:///home/u/a.jai");

    // Windows: strip the slash before the drive letter; `\` -> `/`; re-add the
    // third slash on the way back out. The drive colon is percent-encoded to
    // `%3A` on the way out (it's not in is_uri_safe) — this matches the
    // canonical form VSCode itself emits (`Uri.file(...).toString()`), and
    // path_from_uri decodes it back to `:`.
    assert(path_from_uri_impl("file:///C:/dir/a.jai",   true) == "C:/dir/a.jai");
    assert(path_from_uri_impl("file:///C%3A/dir/a.jai", true) == "C:/dir/a.jai");
    assert(uri_from_path_impl("C:\\dir\\a.jai", true)         == "file:///C%3A/dir/a.jai");
    assert(uri_from_path_impl("C:/dir/a.jai", true)           == "file:///C%3A/dir/a.jai");

    // Windows round-trip: a VSCode-form client URI -> path -> URI is stable.
    win_uri := "file:///C%3A/Users/jdavis/a.jai";
    assert(uri_from_path_impl(path_from_uri_impl(win_uri, true), true) == win_uri);

    // Percent-encoded spaces decode on both platforms.
    assert(path_from_uri_impl("file:///tmp/a%20b.jai", false) == "/tmp/a b.jai");
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
