// jai-lsp entry point.
//
// Owns the read/dispatch loop and the per-message temp-storage reset.
// Everything else lives in dedicated files loaded below.

#import "Basic";

#load "log.jai";
#load "rpc.jai";
#load "protocol.jai";
#load "documents.jai";
#load "analysis.jai";
#load "workspace.jai";
#load "checker.jai";
#load "server.jai";

main :: () {
    // Route every log message — ours or any stdlib accidental — to stderr.
    // stdout is the LSP wire; logging there would corrupt the protocol.
    context.logger = stderr_logger;

    log("jai-lsp starting up (pid awareness not yet wired)");

    server: Server;
    server.inlay_hints_enabled = env_bool("JAI_LSP_INLAY_HINTS", default=true);
    server.entry_file          = env_string("JAI_LSP_ENTRY_FILE");
    log("jai-lsp: inlay_hints_enabled=%", server.inlay_hints_enabled);
    if server.entry_file.count log("jai-lsp: entry_file=% (from env)", server.entry_file);

    while server.running {
        // If a type-check subprocess is in flight, poll stdin with a short
        // timeout so we can also tick the check. When idle, block until a
        // message arrives.
        timeout_ms := ifx server.pending.status == .RUNNING then 25 else -1;

        if poll_stdin(timeout_ms) {
            body, ok := read_message();
            if !ok {
                log("jai-lsp: stdin closed or unreadable; ending session");
                break;
            }
            handle_message(*server, body);
        }

        // Tick the in-flight check (if any). When it finishes, publish.
        tick_pending_check(*server);

        // All per-message scratch (parsed JSON tree, serialized response
        // bytes, log message buffers) was allocated on temp storage. Drop
        // it in one go.
        reset_temporary_storage();
    }

    log("jai-lsp: exiting with code %", server.exit_code);
    exit(xx server.exit_code);
}
