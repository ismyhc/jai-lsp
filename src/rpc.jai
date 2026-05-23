// Content-Length framing over stdio.
//
// Every LSP message on the wire is:
//
//   Content-Length: <N>\r\n
//   (optional other headers, all ignored)
//   \r\n
//   <N bytes of JSON body>
//
// On macOS/Linux we use raw read(2)/write(2) on STDIN_FILENO / STDOUT_FILENO.
// On Windows we use ReadFile/WriteFile on the GetStdHandle handles directly
// (NOT C stdio), which sidesteps the classic \n -> \r\n text-mode translation
// — that mangling only happens through the CRT's text streams, not the raw
// handle. Either way we get byte-exact control with no libc buffering.
//
// All three platforms funnel through os_read_stdin / os_write_stdout below so
// the framing logic stays platform-agnostic.

#import "Basic";
#import "String";

// On Windows we use `Windows.*` (the named import lives once in platform.jai,
// module-wide). On macOS/Linux we pull in POSIX for read/write/poll.
#if OS != .WINDOWS {
    #import "POSIX";
}

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
    #if OS == .WINDOWS {
        // There's no poll()/epoll on a stdin HANDLE. LSP clients hand us a
        // pipe, so we PeekNamedPipe for buffered bytes. A negative timeout
        // means "block until a message arrives": we return true and let the
        // blocking ReadFile in read_message() do the waiting — zero CPU while
        // idle, instead of spinning on Peek.
        if timeout_ms < 0  return true;

        h := Windows.GetStdHandle(Windows.STD_INPUT_HANDLE);
        if h == Windows.INVALID_HANDLE_VALUE  return false;

        STEP :: 5;   // ms between peeks
        elapsed := 0;
        while true {
            avail: u32;
            ok := Windows.PeekNamedPipe(h, null, 0, null, *avail, null);
            if !ok        return true;   // not a pipe (redirected file/console); fall through to a blocking read
            if avail > 0  return true;
            if timeout_ms == 0          return false;
            if elapsed   >= timeout_ms  return false;
            sleep_milliseconds(STEP);
            elapsed += STEP;
        }
        return false;  // unreachable
    } else {
        pfd: pollfd;
        pfd.fd = STDIN_FILENO;
        pfd.events = POLLIN;
        n := poll(*pfd, 1, xx timeout_ms);
        if n <= 0 return false;
        return (pfd.revents & POLLIN) != 0;
    }
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
        n := os_read_stdin(*byte, 1);
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
        n := os_read_stdin(cursor, remaining);
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
        n := os_write_stdout(cursor, remaining);
        if n <= 0 {
            log_error("RPC: write() failed on body");
            return;
        }
        cursor    += n;
        remaining -= n;
    }
}

// --- Platform stdio primitives ---------------------------------------------
//
// Both return byte counts with read(2)/write(2) semantics so the framing
// loops above don't care which OS they're on: >0 = bytes transferred,
// 0 = EOF (read) / would-block, <0 = error.

os_read_stdin :: (buf: *u8, count: int) -> int {
    #if OS == .WINDOWS {
        h := Windows.GetStdHandle(Windows.STD_INPUT_HANDLE);
        if h == Windows.INVALID_HANDLE_VALUE  return -1;
        got: u32;
        ok := Windows.ReadFile(h, buf, xx count, *got, null);
        // A closed write end (client exit) surfaces as ReadFile=FALSE with
        // ERROR_BROKEN_PIPE. Treat any failure as EOF so the loop ends cleanly.
        if !ok  return 0;
        return cast(int) got;
    } else {
        return read(STDIN_FILENO, buf, xx count);
    }
}

os_write_stdout :: (buf: *u8, count: int) -> int {
    #if OS == .WINDOWS {
        h := Windows.GetStdHandle(Windows.STD_OUTPUT_HANDLE);
        if h == Windows.INVALID_HANDLE_VALUE  return -1;
        wrote: u32;
        ok := Windows.WriteFile(h, buf, xx count, *wrote, null);
        if !ok  return -1;
        return cast(int) wrote;
    } else {
        return write(STDOUT_FILENO, buf, xx count);
    }
}
