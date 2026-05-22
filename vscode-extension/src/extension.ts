// Thin shim that spawns ./jai-lsp and pipes JSON-RPC over stdio.
//
// All real work happens in the Jai binary. This file's job is to:
//   1. Resolve the binary path (from settings or PATH).
//   2. Hand it to vscode-languageclient with TransportKind.stdio.
//   3. Stop the client cleanly on deactivate.

import * as path from "node:path";
import * as fs from "node:fs";
import { workspace, ExtensionContext, window } from "vscode";
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

// Resolve the jai-lsp binary path. Priority:
//   1. Explicit `jai-lsp.serverPath` setting (absolute or PATH-relative).
//   2. Platform-specific binary bundled in the extension's bin/ dir, e.g.
//      bin/jai-lsp-darwin-arm64, bin/jai-lsp-windows-x64.exe
//   3. Bare "jai-lsp" — PATH lookup.
function resolveServerPath(ctx: ExtensionContext, configured: string): string {
    if (configured) return configured;

    const ext = process.platform === "win32" ? ".exe" : "";
    const platform = process.platform === "win32" ? "windows" : process.platform;  // darwin/linux/windows
    const arch = process.arch;                                                       // arm64/x64/...
    const bundled = path.join(ctx.extensionPath, "bin", `jai-lsp-${platform}-${arch}${ext}`);
    if (fs.existsSync(bundled)) return bundled;

    return "jai-lsp";
}

export function activate(ctx: ExtensionContext) {
    const cfg = workspace.getConfiguration("jai-lsp");
    const serverPath       = resolveServerPath(ctx, (cfg.get<string>("serverPath") || "").trim());
    const compilerPath     = (cfg.get<string>("compilerPath") || "").trim();
    const entryFile        = (cfg.get<string>("entryFile")    || "").trim();
    const inlayHintEnabled = cfg.get<boolean>("inlayHints.enabled", true);

    // Forward config to the server via env vars (the server reads them at
    // startup). Shell aliases don't propagate into spawned subprocesses,
    // so this is the reliable channel.
    const env = { ...process.env };
    if (compilerPath) env.JAI_COMPILER     = compilerPath;
    if (entryFile)    env.JAI_LSP_ENTRY_FILE = entryFile;
    env.JAI_LSP_INLAY_HINTS = inlayHintEnabled ? "1" : "0";

    const serverOptions: ServerOptions = {
        command: serverPath,
        // No args needed — protocol is over stdio.
        transport: TransportKind.stdio,
        options: { env },
    };

    const clientOptions: LanguageClientOptions = {
        documentSelector: [{ scheme: "file", language: "jai" }],
        // Forward the user's preferred trace level to the client. The server
        // itself writes structured logs to stderr regardless.
        traceOutputChannel: window.createOutputChannel("Jai LSP"),
        synchronize: {
            // Notify the server when .jai files anywhere in the workspace change.
            fileEvents: workspace.createFileSystemWatcher("**/*.jai"),
        },
    };

    client = new LanguageClient(
        "jai-lsp",
        "Jai Language Server",
        serverOptions,
        clientOptions,
    );

    // start() returns a Promise but we don't await — VSCode shows the error
    // ribbon if the server fails to launch.
    client.start().catch((err) => {
        window.showErrorMessage(
            `jai-lsp failed to start (tried '${serverPath}'). ` +
            `Set "jai-lsp.serverPath" in settings to the absolute path of the binary. ` +
            `Details: ${err?.message ?? err}`,
        );
    });
}

export function deactivate(): Thenable<void> | undefined {
    if (!client) return undefined;
    return client.stop();
}
