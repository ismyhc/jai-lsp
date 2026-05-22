// Content-Length framing over stdio.
//
// Every LSP message on the wire is:
//
//   Content-Length: <N>\r\n
//   (optional other headers, all ignored)
//   \r\n
//   <N bytes of JSON body>
//
// We use raw read(2)/write(2) on STDIN_FILENO / STDOUT_FILENO. This gives
// us byte-exact control (no libc buffering surprises) and works the same
// on macOS and Linux. Windows would additionally need _setmode(stdout,
// _O_BINARY) so \n isn't expanded to \r\n on the way out — punt on Windows
// support for now; it's a single #if when we get there.

#import "Basic";
#import "POSIX";
#import "String";

// Read a single framed message body from stdin.
// Returns the body bytes (allocated on the temporary allocator) and ok=true,
// or an empty string + ok=false on EOF or a malformed frame.
read_message :: () -> body: string, ok: bool {
    // 1. Read headers up to and including the terminating \r\n\r\n.
    headers, headers_ok := read_headers();
    if !headers_ok return "", false;

    // 2. Find Content-Length.
    content_length, cl_ok := parse_content_length(headers);
    if !cl_ok {
        log_error("RPC: missing or invalid Content-Length header. Headers were: %", headers);
        return "", false;
    }
    if content_length < 0 || content_length > MAX_MESSAGE_SIZE {
        log_error("RPC: refusing implausible Content-Length: %", content_length);
        return "", false;
    }

    // 3. Read exactly content_length body bytes.
    buf := cast(*u8) talloc(content_length);
    if !read_exact(buf, content_length) {
        log_error("RPC: short read on body (expected % bytes)", content_length);
        return "", false;
    }

    body: string;
    body.data  = buf;
    body.count = content_length;
    return body, true;
}

// Wait up to `timeout_ms` for stdin to have data ready. Returns true if
// poll() reports POLLIN set. -1 = block indefinitely; 0 = pure non-blocking
// check; positive = timeout in milliseconds.
//
// Used by the main loop so it can interleave between handling messages and
// polling background work (e.g., the in-flight type-check subprocess)
// without spinning.
poll_stdin :: (timeout_ms: int) -> bool {
    pfd: pollfd;
    pfd.fd = STDIN_FILENO;
    pfd.events = POLLIN;
    n := poll(*pfd, 1, xx timeout_ms);
    if n <= 0 return false;
    return (pfd.revents & POLLIN) != 0;
}

// Write a framed message. `body` is the JSON payload bytes.
write_message :: (body: string) {
    // Header + body in two write(2) calls. We don't need to fuse them — the
    // kernel doesn't tear stdout writes across processes, and clients read
    // header-then-body anyway.
    header := tprint("Content-Length: %\r\n\r\n", body.count);
    write_all(header.data, header.count);
    write_all(body.data,   body.count);
}

#scope_file

// Cap inbound messages at 16 MiB. Real LSP traffic is tiny (a hover request
// is ~200 bytes); anything larger is almost certainly a desync or a bug.
MAX_MESSAGE_SIZE :: 16 * 1024 * 1024;

// Read bytes one at a time until we've seen \r\n\r\n, return everything
// up to (but not including) that terminator.
read_headers :: () -> string, bool {
    builder: String_Builder;
    builder.allocator = temp;

    // Tiny state machine matching the four-byte terminator.
    state := 0;  // counts how many of \r\n\r\n we've matched so far
    byte: u8;

    while true {
        n := read(STDIN_FILENO, *byte, 1);
        if n == 0 {
            // EOF before headers completed. If we've read nothing, this is
            // a clean close (client exited); otherwise it's truncation.
            if state == 0 && builder_string_length(*builder) == 0 {
                return "", false;
            }
            log_error("RPC: EOF mid-header");
            return "", false;
        }
        if n < 0 {
            log_error("RPC: read() failed on header");
            return "", false;
        }

        append(*builder, byte);

        if state == {
            case 0; if byte == #char "\r" state = 1;
            case 1; state = ifx byte == #char "\n" then 2 else 0;
            case 2; state = ifx byte == #char "\r" then 3 else 0;
            case 3;
                if byte == #char "\n" {
                    // Strip the trailing \r\n\r\n we just appended.
                    full := builder_to_string(*builder,, temp);
                    if full.count >= 4 full.count -= 4;
                    return full, true;
                }
                state = 0;
        }

        // Guard against pathological clients that never send the terminator.
        if builder_string_length(*builder) > 64 * 1024 {
            log_error("RPC: header section exceeded 64KiB, giving up");
            return "", false;
        }
    }
    return "", false;  // unreachable
}

parse_content_length :: (headers: string) -> int, bool {
    // Headers are CRLF-separated lines of "Name: Value". We only care about
    // Content-Length (case-insensitive per the LSP base protocol, but in
    // practice always sent as "Content-Length").
    remainder := headers;
    while remainder.count {
        line: string;
        line, remainder = split_line(remainder);
        line = trim(line);
        if !line.count continue;

        colon := find_index_from_left(line, #char ":");
        if colon < 0 continue;

        name  := trim(slice(line, 0, colon));
        value := trim(slice(line, colon + 1, line.count - colon - 1));

        if equal_nocase(name, "Content-Length") {
            n, ok, _ := string_to_int(value);
            if !ok return 0, false;
            return n, true;
        }
    }
    return 0, false;
}

// Pop the first line off `s`, returning (line_without_crlf, rest).
split_line :: (s: string) -> string, string {
    if !s.count return "", "";
    for 0..s.count - 1 {
        if s[it] == #char "\n" {
            line: string;
            line.data  = s.data;
            line.count = it;
            // Drop trailing \r if present.
            if line.count > 0 && line[line.count - 1] == #char "\r" {
                line.count -= 1;
            }
            rest: string;
            rest.data  = s.data + it + 1;
            rest.count = s.count - it - 1;
            return line, rest;
        }
    }
    return s, "";
}

// read(2) may return fewer bytes than requested even on a regular stream —
// loop until we've filled the whole buffer or hit EOF/error.
read_exact :: (buf: *u8, count: int) -> bool {
    remaining := count;
    cursor    := buf;
    while remaining > 0 {
        n := read(STDIN_FILENO, cursor, xx remaining);
        if n == 0 return false;       // unexpected EOF
        if n <  0 return false;       // error
        cursor    += n;
        remaining -= n;
    }
    return true;
}

write_all :: (buf: *u8, count: int) {
    remaining := count;
    cursor    := buf;
    while remaining > 0 {
        n := write(STDOUT_FILENO, cursor, xx remaining);
        if n <= 0 {
            log_error("RPC: write() failed on body");
            return;
        }
        cursor    += n;
        remaining -= n;
    }
}
