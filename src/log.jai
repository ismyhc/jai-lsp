// Stderr-only logging.
//
// IMPORTANT: stdout is the LSP wire. We must never write log output to it.
//
// `print` from Basic writes to stdout — DO NOT use it anywhere in this program.
// Use `log` / `log_error` (which route through `context.logger`) after main()
// has installed `stderr_logger`. The logger writes every message — error or
// not — to stderr via the raw write(2) syscall, so even an accidental log
// from a stdlib module stays off the wire.

#import "POSIX";

stderr_logger :: (message: string, data: *void, info: Log_Info) {
    if !message.count return;

    // Raw write to stderr; bypass libc buffering so messages aren't held
    // back during a crash. Best-effort: nothing sensible to do if stderr
    // itself fails.
    write(STDERR_FILENO, message.data, xx message.count);

    // Make sure each log ends with a newline for human readability.
    if message[message.count - 1] != #char "\n" {
        nl: u8 = #char "\n";
        write(STDERR_FILENO, *nl, 1);
    }
}
