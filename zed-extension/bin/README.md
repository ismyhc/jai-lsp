# Bundled binaries

The Zed extension looks here at activation for a binary matching
`current_platform()`. Drop in any subset of:

```
jai-lsp-darwin-arm64
jai-lsp-darwin-x64
jai-lsp-linux-x64
jai-lsp-linux-arm64
jai-lsp-windows-x64.exe
```

Make them executable on Unix:

```sh
chmod +x bin/jai-lsp-*
```

If nothing matches the user's platform, the extension falls back to the
`lsp.jai-lsp.binary.path` setting, then to PATH lookup for `jai-lsp`.
