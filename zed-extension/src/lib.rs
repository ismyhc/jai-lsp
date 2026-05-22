// Zed extension glue: tells Zed how to launch jai-lsp.
//
// The real language server lives in the parent crate's `jai-lsp` binary.
// This crate is a tiny WASM shim Zed loads to spawn it.
//
// Configuration:
//   * Binary path: Zed resolves it via Worktree::which("jai-lsp"), or via
//     the user's `lsp.jai-lsp.binary.path` setting (handled here).
//   * jai-lsp's own settings (compilerPath, entryFile, inlayHints.enabled)
//     are forwarded via env vars by reading them out of the LSP settings
//     block — same mechanism as the VSCode extension.

use std::fs;
use zed_extension_api::{
    self as zed, current_platform, settings::LspSettings, Architecture, Command, LanguageServerId,
    Os, Result, Worktree,
};

struct JaiExtension;

impl zed::Extension for JaiExtension {
    fn new() -> Self {
        JaiExtension
    }

    fn language_server_command(
        &mut self,
        language_server_id: &LanguageServerId,
        worktree: &Worktree,
    ) -> Result<Command> {
        // Binary resolution priority:
        //   1. Explicit `lsp.jai-lsp.binary.path` setting.
        //   2. Platform-specific binary bundled in this extension's bin/ dir.
        //   3. `jai-lsp` on the user's PATH (resolved via Worktree::which).
        let lsp_settings = LspSettings::for_worktree(language_server_id.as_ref(), worktree).ok();
        let configured_path = lsp_settings
            .as_ref()
            .and_then(|s| s.binary.as_ref())
            .and_then(|b| b.path.clone());

        let path = match configured_path {
            Some(p) if !p.is_empty() => p,
            _ => bundled_binary_path().or_else(|| worktree.which("jai-lsp")).ok_or_else(|| {
                "jai-lsp not found. Either bundle a binary in the extension's bin/ dir, \
                 add `jai-lsp` to PATH, or set `lsp.jai-lsp.binary.path` in Zed settings."
                    .to_string()
            })?,
        };

        // Start the LSP process with the user's full shell environment.
        // Zed's spawned subprocesses don't inherit the shell env by default,
        // so `jai` (which usually lives at a path the shell knows about but
        // not the GUI Zed process) isn't reachable. Pull the shell env from
        // the worktree and forward it; the LSP then spawns its own subprocess
        // (the compiler check) and PATH lookups resolve.
        let mut env: Vec<(String, String)> = worktree.shell_env();

        // Apply jai-lsp-specific settings on top (override env if the user
        // set them explicitly).
        if let Some(settings_value) = lsp_settings.as_ref().and_then(|s| s.settings.as_ref()) {
            if let Some(jai) = settings_value.get("jai-lsp") {
                if let Some(s) = jai.get("compilerPath").and_then(|v| v.as_str()) {
                    if !s.is_empty() {
                        env.push(("JAI_COMPILER".into(), s.into()));
                    }
                }
                if let Some(s) = jai.get("entryFile").and_then(|v| v.as_str()) {
                    if !s.is_empty() {
                        env.push(("JAI_LSP_ENTRY_FILE".into(), s.into()));
                    }
                }
                if let Some(b) = jai.get("inlayHints.enabled").and_then(|v| v.as_bool()) {
                    env.push((
                        "JAI_LSP_INLAY_HINTS".into(),
                        if b { "1" } else { "0" }.into(),
                    ));
                }
            }
        }

        Ok(Command {
            command: path,
            args: Vec::new(),
            env,
        })
    }
}

/// Look for bin/jai-lsp-<os>-<arch>[.exe] sitting next to the extension.
/// Returns None if the file doesn't exist for this platform.
fn bundled_binary_path() -> Option<String> {
    let (os, arch) = current_platform();
    let os_str = match os {
        Os::Mac => "darwin",
        Os::Linux => "linux",
        Os::Windows => "windows",
    };
    let arch_str = match arch {
        Architecture::Aarch64 => "arm64",
        Architecture::X8664 => "x64",
        Architecture::X86 => "x86",
    };
    let ext = if matches!(os, Os::Windows) { ".exe" } else { "" };
    let candidate = format!("./bin/jai-lsp-{os_str}-{arch_str}{ext}");
    fs::metadata(&candidate).ok().map(|_| candidate)
}

zed::register_extension!(JaiExtension);
