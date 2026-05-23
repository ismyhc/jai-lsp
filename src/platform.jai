// Platform shims.
//
// The Windows module is imported here exactly once, at module scope, so every
// other file (rpc.jai, log.jai, checker.jai) can reference `Windows.*` without
// re-declaring it. A *named* import (`Windows :: #import ...`) is a top-level
// constant, and top-level constants are shared across a module's #loaded
// files — declaring it in two files would be a duplicate-symbol error. (The
// unnamed `#import "POSIX"` used on macOS/Linux dedups cleanly, so that one
// stays per-file where it's needed.)

#if OS == .WINDOWS {
    Windows :: #import "Windows";
}
