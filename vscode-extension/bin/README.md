# Bundled binaries

The extension resolves the right binary from this folder at activation time
based on `process.platform` and `process.arch`. Drop in any subset of:

```
jai-lsp-darwin-arm64        # Apple Silicon Mac
jai-lsp-darwin-x64          # Intel Mac
jai-lsp-linux-x64
jai-lsp-linux-arm64
jai-lsp-windows-x64.exe
```

Make them executable on Unix targets:

```sh
chmod +x bin/jai-lsp-*
```

If a binary for the user's platform is missing, the extension falls back to
`jai-lsp.serverPath` (if set), then to `jai-lsp` on PATH.

## Build steps (one-time on each target machine)

```sh
cd ..                                 # back to repo root
jai build.jai                         # produces ./jai-lsp
mv jai-lsp vscode-extension/bin/jai-lsp-<platform>-<arch>[.exe]
```

For platform-specific marketplace VSIXes (one VSIX per platform, served by
the marketplace per user), see `vsce package --target <target>`. Until then,
shipping one VSIX with all the binaries is the simpler path.
