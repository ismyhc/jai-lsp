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

    while server.running {
        body, ok := read_message();
        if !ok {
            // Clean EOF or unrecoverable framing error. Either way, the
            // session is done. We don't honor the shutdown/exit dance here
            // because there's no client left to honor it with.
            log("jai-lsp: stdin closed or unreadable; ending session");
            break;
        }

        handle_message(*server, body);

        // All per-message scratch (parsed JSON tree, serialized response
        // bytes, log message buffers) was allocated on temp storage. Drop
        // it in one go.
        reset_temporary_storage();
    }

    log("jai-lsp: exiting with code %", server.exit_code);
    exit(xx server.exit_code);
}
