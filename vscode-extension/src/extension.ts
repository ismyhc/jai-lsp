// Thin shim that spawns ./jai-lsp and pipes JSON-RPC over stdio.
//
// All real work happens in the Jai binary. This file's job is to:
//   1. Resolve the binary path (from settings or PATH).
//   2. Hand it to vscode-languageclient with TransportKind.stdio.
//   3. Stop the client cleanly on deactivate.

import * as path from "node:path";
import { workspace, ExtensionContext, window } from "vscode";
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(_ctx: ExtensionContext) {
    const cfg = workspace.getConfiguration("jai-lsp");
    const serverPath   = (cfg.get<string>("serverPath")   || "jai-lsp").trim();
    const compilerPath = (cfg.get<string>("compilerPath") || "").trim();

    // Forward the compiler path via env var so the diagnostics subprocess
    // can find `jai` even when the user's `jai` is a shell alias (aliases
    // don't propagate into spawned processes).
    const env = { ...process.env };
    if (compilerPath) env.JAI_COMPILER = compilerPath;

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
