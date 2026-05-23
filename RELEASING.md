# Releasing jai-lsp

Step-by-step for cutting a release and publishing the editor extensions.
Assumes you have shell access to at least one machine per target platform
(macOS arm64, macOS x64, Linux x64, Windows x64) since the Jai compiler
isn't on public CI and the binaries must be built on the target OS.

The process splits into four phases:

1. [Prepare](#1-prepare) — bump versions, write changelog
2. [Build per-platform binaries](#2-build-per-platform-binaries) — run on each target machine
3. [Tag + GitHub release](#3-tag--github-release) — push, create release, upload binaries
4. [Publish editor extensions](#4-publish-editor-extensions) — VSCode Marketplace, Zed registry

A first-time release needs the one-time setup in
[Appendix A](#appendix-a-one-time-publisher-setup).

---

## 1. Prepare

Pick the new version (semver). For this guide assume **`v0.1.0`**.

Update the version in three files:

```sh
# vscode-extension/package.json
"version": "0.1.0",

# zed-extension/extension.toml
version = "0.1.0"

# tree-sitter-jai/package.json   (only if grammar changed since last release)
"version": "0.1.0",
```

Write a short changelog entry — either in commit messages or a top-of-file
`CHANGELOG.md`. Quality > formality.

```sh
git add vscode-extension/package.json zed-extension/extension.toml
git commit -m "release: v0.1.0"
```

---

## 2. Build per-platform binaries

Do this on each target platform. The `package.jai` metaprogram builds the
server, names it correctly for the platform, and copies it into both
extensions' `bin/` directories.

```sh
# On each target machine, from the repo root:
git pull
jai package.jai

# Verify the binary landed where expected:
ls -la vscode-extension/bin/   zed-extension/bin/
# vscode-extension/bin/jai-lsp-darwin-arm64
# zed-extension/bin/jai-lsp-darwin-arm64
```

`package.jai` detects the host OS+CPU automatically. Platforms produced:

| OS        | CPU    | Binary name                |
| --------- | ------ | -------------------------- |
| macOS     | arm64  | `jai-lsp-darwin-arm64`     |
| macOS     | x64    | `jai-lsp-darwin-x64`       |
| Linux     | x64    | `jai-lsp-linux-x64`        |
| Linux     | arm64  | `jai-lsp-linux-arm64`      |
| Windows   | x64    | `jai-lsp-windows-x64.exe`  |

After running `package.jai` on every machine, **collect all the resulting
binaries onto a single machine** (where you'll do the rest of the release).
Drop them into the same `bin/` paths on that machine:

```
vscode-extension/bin/
  jai-lsp-darwin-arm64
  jai-lsp-darwin-x64
  jai-lsp-linux-x64
  jai-lsp-windows-x64.exe

zed-extension/bin/
  (same set)
```

These `bin/jai-lsp-*` paths are `.gitignore`'d on purpose — they get
attached to the GitHub Release and bundled into per-platform VSIXes, not
committed.

---

## 3. Tag + GitHub release

```sh
git tag v0.1.0
git push
git push --tags
```

Create the release with all binaries attached:

```sh
gh release create v0.1.0 \
    vscode-extension/bin/jai-lsp-darwin-arm64 \
    vscode-extension/bin/jai-lsp-darwin-x64 \
    vscode-extension/bin/jai-lsp-linux-x64 \
    vscode-extension/bin/jai-lsp-linux-arm64 \
    vscode-extension/bin/jai-lsp-windows-x64.exe \
    --title "v0.1.0" \
    --notes "<paste your changelog here>"
```

(Skip any platform you didn't build for. The release works fine with a
subset; users on missing platforms just won't have a prebuilt binary.)

Confirm the release exists and the assets uploaded:

```sh
gh release view v0.1.0
```

At this point, source users can already `git clone + jai build.jai` for
the new version, and anyone who downloads a binary from the release works
with the existing extensions.

---

## 4. Publish editor extensions

### 4a. VSCode Marketplace

VSCode supports **platform-specific extensions** — you publish a separate
VSIX per platform, each bundling only that platform's binary. The
marketplace serves the right one to each user.

```sh
cd vscode-extension
npm install                # full install (devDeps needed to compile)
npm run compile            # build out/extension.js
npm prune --production     # drop devDeps so the VSIX stays small

# Package one VSIX per platform (each picks up only its own binary from bin/).
# The .vscodeignore is set up to include bin/*, but vsce --target picks the
# right one based on file naming.
npx @vscode/vsce package --target darwin-arm64
npx @vscode/vsce package --target darwin-x64
npx @vscode/vsce package --target linux-x64
npx @vscode/vsce package --target win32-x64

# Restore devDeps so you can keep developing.
npm install

# Publish them all (requires `vsce login` from the appendix).
npx @vscode/vsce publish --packagePath \
    jai-lsp-vscode-0.1.0-darwin-arm64.vsix \
    jai-lsp-vscode-0.1.0-darwin-x64.vsix \
    jai-lsp-vscode-0.1.0-linux-x64.vsix \
    jai-lsp-vscode-0.1.0-win32-x64.vsix
```

After publish (~10 min for marketplace to refresh), users can install via
the Extensions panel or `code --install-extension <publisher>.jai-lsp`.

**Skipping per-platform packaging:** if you only have one platform built,
you can ship a single non-platform-specific VSIX (`vsce package` with no
`--target`). All users get all binaries in their download — works fine,
just larger.

### 4b. Zed extension registry

Zed extensions are submitted as PRs against
[`zed-industries/extensions`](https://github.com/zed-industries/extensions).

```sh
# Fork that repo if you haven't, then add an entry:
git clone https://github.com/<your-fork>/zed-industries-extensions
cd zed-industries-extensions
git checkout -b add-jai-lsp

# Add a directory under extensions/ named after the extension id ("jai"):
mkdir -p extensions/jai
cp /Users/jdavis/Development/jai-lsp/zed-extension/extension.toml extensions/jai/

# Register it in the top-level extensions.toml:
# (Append to that file)
cat >> extensions.toml <<EOF

[jai]
submodule = "extensions/jai"
version   = "0.1.0"
EOF

# Or if Zed has moved to a different submission format, follow the README
# of that repo — the requirements drift between Zed releases.

git add . && git commit -m "Add jai-lsp extension v0.1.0"
git push -u origin add-jai-lsp
gh pr create --title "Add jai-lsp extension v0.1.0" --body "..."
```

After the PR merges, Zed users can install via ⌘⇧P → "zed: install
extension" → search "Jai".

### 4c. Neovim — no central registry

Neovim plugin managers (lazy.nvim, packer, vim-plug) install directly from
Git URLs. Once your tag is pushed, users referencing `"ismyhc/jai-lsp"`
get the new version on their next plugin update.

If you want to be in [awesome-neovim](https://github.com/rockerBOO/awesome-neovim)
or similar curated lists, submit PRs to those.

### 4d. Emacs — no central registry for this style

Same as Neovim — users clone the repo and `(require 'jai-lsp)`. MELPA
submission is possible but involves curation; ELPA is gated. For now,
README install instructions are sufficient.

---

## Quick reference (TL;DR)

```sh
# Per-platform machines:
git pull && jai package.jai

# Centrally:
# (after collecting all binaries into vscode-extension/bin and zed-extension/bin)
git tag v0.1.0 && git push --tags

gh release create v0.1.0 \
    vscode-extension/bin/jai-lsp-* \
    --title "v0.1.0" --notes "..."

cd vscode-extension
npm install && npm run compile && npm prune --production
for target in darwin-arm64 darwin-x64 linux-x64 win32-x64; do
    npx @vscode/vsce package --target "$target"
done
npx @vscode/vsce publish --packagePath *.vsix
npm install   # restore devDeps
```

---

## Appendix A: one-time publisher setup

### VSCode Marketplace publisher

1. Create a publisher at https://marketplace.visualstudio.com/manage
2. Create a Personal Access Token at https://dev.azure.com → User Settings → Personal Access Tokens, scope **Marketplace → Manage**
3. Locally:
   ```sh
   npx @vscode/vsce login <your-publisher-name>
   # Paste the PAT when prompted
   ```
4. Set the same publisher name in `vscode-extension/package.json`'s
   `publisher` field.

### Zed extension registry

1. Fork `zed-industries/extensions` once.
2. Have a working GitHub account that can open PRs.

### GitHub release uploads

1. `gh auth login` once, with `repo` scope.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `vsce package` fails: "missing publisher" | Add `"publisher": "<name>"` to `vscode-extension/package.json` |
| Users install VSIX but extension says "spawn jai-lsp ENOENT" | The VSIX didn't include the binary for that platform. Verify `bin/jai-lsp-<platform>-<arch>` exists in the VSIX (`unzip -l *.vsix`). Per-platform packaging fixes this |
| Extension fails to activate: "Cannot find module 'vscode-languageclient/node'" | `node_modules/` got stripped from the VSIX (old `.vscodeignore` had `node_modules/**`). Make sure your `.vscodeignore` keeps runtime deps. Re-package |
| `tsc` fails with "Cannot find module 'vscode'" during a release build | You ran `npm prune --production` before `npm run compile`. Order matters: install → compile → prune → package |
| Zed extension PR rejected | Check the upstream `extensions` repo's CONTRIBUTING for the current schema; format changes occasionally |
| `gh release create` says "tag already exists" | The tag was pushed but no release was created. Use `gh release create v0.1.0 ...` exactly the same way; gh attaches to the existing tag |
