// Open-document store and position math.
//
// The store maps document URI -> Document, owning the full text + a
// line-start byte index. Documents live in context.allocator (heap) and
// outlive any single message; the store frees on close.
//
// Position math is encoding-aware. LSP `Position.character` is, per the
// spec, a *UTF-16 code unit* offset by default — but a client may agree
// to `utf-8` (byte offset) during initialize. Both are supported here so
// the rest of the server can speak in byte offsets internally.

#import "Basic";
#import "Hash_Table";

Position_Encoding :: enum u8 {
    UTF_16 :: 0;   // LSP default
    UTF_8  :: 1;   // negotiated when the client advertises it
}

Document :: struct {
    uri:         string;       // owned copy
    version:     int;
    text:        string;       // owned copy; UTF-8 bytes
    line_starts: [..] int;     // byte offset of each line's first byte
                               // (line_starts[0] is always 0)
}

Document_Store :: struct {
    docs: Table(string, *Document);
}

// --- Lifecycle --------------------------------------------------------------

store_open :: (store: *Document_Store, uri: string, version: int, text: string) {
    // Replace any existing entry — some clients send didOpen twice for the
    // same URI (e.g., after a workspace folder change).
    existing := table_find_pointer(*store.docs, uri);
    if existing free_document(existing.*);

    doc := New(Document);
    doc.uri     = copy_string(uri);
    doc.version = version;
    doc.text    = copy_string(text);
    rebuild_line_index(doc);

    table_set(*store.docs, doc.uri, doc);
}

store_change :: (store: *Document_Store, uri: string, version: int, new_text: string) -> bool {
    slot := table_find_pointer(*store.docs, uri);
    if !slot {
        log_error("Documents: didChange for unknown uri %", uri);
        return false;
    }
    doc := slot.*;

    free(doc.text);
    doc.text    = copy_string(new_text);
    doc.version = version;
    rebuild_line_index(doc);
    return true;
}

store_close :: (store: *Document_Store, uri: string) {
    found, doc := table_find(*store.docs, uri);
    if !found return;
    table_remove(*store.docs, uri);
    free_document(doc);
}

store_get :: (store: *Document_Store, uri: string) -> *Document {
    found, doc := table_find(*store.docs, uri);
    if !found return null;
    return doc;
}

// --- Position math ----------------------------------------------------------

// Convert an LSP Position to a byte offset into the document text.
// Returns -1 if the position is out of range.
//
// `character` is interpreted according to `encoding`:
//   * UTF_8  → byte offset within the line
//   * UTF_16 → UTF-16 code-unit offset within the line
//
// Positions past end-of-line clamp to end-of-line; positions past end-of-doc
// clamp to end-of-doc. This matches most clients' behavior.
position_to_byte_offset :: (doc: *Document, line: int, character: int, encoding: Position_Encoding) -> int {
    if line < 0 return -1;
    if line >= doc.line_starts.count {
        // Past the last line — clamp to end of document.
        return doc.text.count;
    }

    line_start := doc.line_starts[line];
    line_end:   int;
    if line + 1 < doc.line_starts.count {
        // The next line's start, minus the newline byte. We need to detect
        // \r\n vs \n to compute the line's exclusive end correctly.
        next := doc.line_starts[line + 1];
        line_end = next - 1;   // drop \n
        if line_end > line_start && doc.text[line_end - 1] == #char "\r" {
            line_end -= 1;
        }
    } else {
        line_end = doc.text.count;
    }

    if character <= 0 return line_start;

    if encoding == .UTF_8 {
        offset := line_start + character;
        if offset > line_end offset = line_end;
        return offset;
    }

    // UTF-16: walk UTF-8 bytes, counting UTF-16 code units.
    units_remaining := character;
    i := line_start;
    while i < line_end && units_remaining > 0 {
        cp_bytes, cp_utf16_units := utf8_step(doc.text, i, line_end);
        if cp_utf16_units > units_remaining {
            // Position lands inside a surrogate pair — round down to the
            // codepoint boundary rather than producing an invalid offset.
            break;
        }
        units_remaining -= cp_utf16_units;
        i               += cp_bytes;
    }
    return i;
}

// Convert a 0-based byte offset within a line into the corresponding offset
// in the negotiated encoding. Takes raw (text, line_starts) so it works
// outside the Document context — workspace indexing of on-disk files needs
// to convert positions without building a full Document.
byte_col_to_encoding_col :: (text: string, line_starts: [] int, line: int, byte_col: int, encoding: Position_Encoding) -> int {
    if encoding == .UTF_8 return byte_col;
    if line < 0 || line >= line_starts.count return 0;

    line_start := line_starts[line];
    target     := line_start + byte_col;
    if target > text.count target = text.count;

    units := 0;
    i := line_start;
    while i < target {
        cp_bytes, cp_units := utf8_step(text, i, target);
        units += cp_units;
        i     += cp_bytes;
    }
    return units;
}

line_length_in_encoding_units :: (text: string, line_starts: [] int, line: int, encoding: Position_Encoding) -> int {
    if line < 0 || line >= line_starts.count return 0;
    line_start := line_starts[line];
    line_end:   int;
    if line + 1 < line_starts.count {
        line_end = line_starts[line + 1] - 1;  // drop \n
        if line_end > line_start && text[line_end - 1] == #char "\r" line_end -= 1;
    } else {
        line_end = text.count;
    }
    return byte_col_to_encoding_col(text, line_starts, line, line_end - line_start, encoding);
}

// Build a fresh line-start index for arbitrary text. Caller owns the array.
compute_line_starts :: (text: string) -> [..] int {
    starts: [..] int;
    array_add(*starts, 0);
    if !text.count return starts;
    for i: 0..text.count - 1 {
        if text[i] == #char "\n" array_add(*starts, i + 1);
    }
    return starts;
}

// --- Internals --------------------------------------------------------------

rebuild_line_index :: (doc: *Document) {
    array_reset(*doc.line_starts);
    array_add(*doc.line_starts, 0);
    if !doc.text.count return;
    for i: 0..doc.text.count - 1 {
        if doc.text[i] == #char "\n" {
            array_add(*doc.line_starts, i + 1);
        }
    }
}

// Decode one UTF-8 codepoint starting at `text[i]`. Returns the number of
// bytes consumed and the number of UTF-16 code units it contributes.
// On invalid sequences, advances by 1 byte and reports 1 unit — we never
// stall the position walk on malformed input.
utf8_step :: (text: string, i: int, end: int) -> bytes: int, utf16_units: int {
    b0 := text[i];
    if b0 < 0x80          return 1, 1;   // ASCII
    if (b0 & 0xE0) == 0xC0 {
        if i + 1 < end    return 2, 1;
        return 1, 1;
    }
    if (b0 & 0xF0) == 0xE0 {
        if i + 2 < end    return 3, 1;
        return 1, 1;
    }
    if (b0 & 0xF8) == 0xF0 {
        if i + 3 < end    return 4, 2;   // supplementary plane → surrogate pair
        return 1, 1;
    }
    // Invalid leading byte (continuation byte at start, or 5/6-byte form).
    return 1, 1;
}

free_document :: (doc: *Document) {
    free(doc.text);
    free(doc.uri);
    array_free(doc.line_starts);
    free(doc);
}
