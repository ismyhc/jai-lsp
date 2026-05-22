// Package metaprogram for the VSCode + Zed extensions.
//
// Run with:  jai package.jai
//
// What it does:
//   1. Builds ./jai-lsp for the host platform (NO_OUTPUT for this workspace).
//   2. Copies the binary into vscode-extension/bin/ AND zed-extension/bin/
//      with the platform/arch suffix the extensions expect, e.g.
//      jai-lsp-darwin-arm64, jai-lsp-windows-x64.exe.
//   3. chmod +x on Unix.
//
// Build this on each target machine (or cross-compile if Jai supports it
// for your target) and the resulting bin/ entries get bundled into the
// VSIX / Zed extension when you package.

#import "Basic";
#import "Compiler";
#import "File";
#if OS != .WINDOWS  #import "POSIX";

BUILD_DIR :: ".build-package";

build :: () {
    suffix := platform_suffix();
    if !suffix.count {
        log_error("package: unsupported platform/CPU combination (OS=%, CPU=%)", OS, CPU);
        set_build_options_dc(.{do_output=false});
        return;
    }

    // Compile main.jai into a fresh child workspace.
    w := compiler_create_workspace("jai-lsp-package");
    if !w {
        log_error("package: failed to create workspace");
        set_build_options_dc(.{do_output=false});
        return;
    }

    make_directory_if_it_does_not_exist(BUILD_DIR);

    options := get_build_options(w);
    options.output_executable_name = "jai-lsp";
    options.output_path            = tprint("./%/", BUILD_DIR);
    set_build_options(options, w);

    failed := false;
    compiler_begin_intercept(w);     // must precede add_build_file
    add_build_file("src/main.jai", w);
    while true {
        m := compiler_wait_for_message();
        if m.kind == .COMPLETE {
            mc := cast(*Message_Complete) m;
            if mc.error_code != .NONE failed = true;
            break;
        }
    }
    compiler_end_intercept(w);

    if failed {
        log_error("package: child workspace compile failed; not copying anything");
        set_build_options_dc(.{do_output=false});
        return;
    }

    ext := ifx OS == .WINDOWS then ".exe" else "";
    built := tprint("./%/jai-lsp%", BUILD_DIR, ext);
    dest_name := tprint("jai-lsp-%%", suffix, ext);

    targets := string.[
        "vscode-extension/bin",
        "zed-extension/bin",
    ];
    for targets {
        make_directory_if_it_does_not_exist(it);
        dest := tprint("%/%", it, dest_name);
        if !copy_file_bytes(built, dest) {
            log_error("package: failed to copy '%' → '%'", built, dest);
            continue;
        }
        #if OS != .WINDOWS {
            // chmod 0755 (rwxr-xr-x). Jai has no octal literal, so we use decimal.
            cpath := tprint("%\0", dest);
            rc := chmod(cpath.data, 493);   // 0o755 == 493
            if rc != 0 log_error("package: chmod failed for %", dest);
        }
        log("package: ✓ %", dest);
    }

    set_build_options_dc(.{do_output=false});
}

platform_suffix :: () -> string {
    #if OS == .MACOS {
        #if CPU == .ARM64  return "darwin-arm64";
        else #if CPU == .X64    return "darwin-x64";
    } else #if OS == .LINUX {
        #if CPU == .ARM64  return "linux-arm64";
        else #if CPU == .X64    return "linux-x64";
    } else #if OS == .WINDOWS {
        #if CPU == .X64    return "windows-x64";
    }
    return "";
}

// File module doesn't ship a copy_file, so we do a plain read+write. Fine
// for a binary that's under a couple of MB.
copy_file_bytes :: (src: string, dest: string) -> bool {
    data, ok := read_entire_file(src);
    if !ok return false;
    defer free(data);
    return write_entire_file(dest, data);
}

#run build();
