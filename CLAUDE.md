# CLAUDE.md — jai-lsp

A Language Server for the **Jai** programming language, **written in Jai**. Speaks
the Language Server Protocol (LSP) over stdio so it works in VSCode, Neovim, Helix,
Zed, and any other LSP client. The VSCode integration is a thin TypeScript shim that
launches the compiled Jai binary as a child process.

This is a dogfooding project: a Jai tool that makes writing Jai better.

---

## Core principles (project conventions)

- **Architecture first.** No feature code lands before its data flow is described here.
- **Minimal dependencies.** Jai stdlib only on the server side. The VSCode side uses
  exactly one npm dep (`vscode-languageclient`) plus the VSCode API.
- **Manual memory, explicit lifetimes.** Per-message scratch goes on temporary storage
  and is reset after each message. Anything that outlives a message (document text,
  symbol index) lives in a long-lived allocator.
- **stdout is sacred.** It is the protocol channel. *Never* `print` to it. All logging
  goes to stderr or a log file.
- **The transport is not VSCode-specific.** We are building an LSP server, not a VSCode
  plugin. VSCode is just the first client.

---

## The big picture

```
┌─────────────────┐         stdio (JSON-RPC 2.0)        ┌──────────────────────┐
│  VSCode          │  ──────────────────────────────▶   │  jai-lsp (Jai binary) │
│  + thin TS shim  │  ◀──────────────────────────────   │  the actual server    │
└─────────────────┘   Content-Length framed messages    └──────────────────────┘
```

Two deliverables:

1. **`jai-lsp`** — the server. All real work happens here. A standalone executable
   that reads JSON-RPC from stdin and writes it to stdout.
2. **`vscode-extension/`** — ~30 lines of TypeScript using `vscode-languageclient`
   that spawns `jai-lsp` with `TransportKind.stdio`. This is the only non-Jai code.

---

## Transport: how LSP framing works

LSP is JSON-RPC 2.0 with HTTP-style framing. Every message on the wire is:

```
Content-Length: 123\r\n
\r\n
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{...}}
```

The read loop is:

1. Read bytes until `\r\n\r\n` (end of headers).
2. Parse the `Content-Length:` header → `N`.
3. Read **exactly** `N` bytes — that's the JSON body.
4. Decode the body, dispatch on `method`, write a framed response (if it's a request).

**Requests vs notifications:** a message with an `id` is a *request* and needs a
response. A message with no `id` is a *notification* and gets **no** reply
(e.g. `textDocument/didChange`). Sending a response to a notification is a protocol
error.

---

## Standard library modules in play

| Module       | Used for                                                        |
|--------------|-----------------------------------------------------------------|
| `Basic`      | alloc/free, `String_Builder`, `tprint`, temp storage, logging   |
| `String`     | `split`, `trim`, `begins_with`, find/compare on text            |
| `jaison`     | JSON parse / encode                                             |
| `Hash_Table` | `Table(string, Document)` — the open-document store             |
| `Jai_Lexer`  | **the dogfood win** — tokenizes Jai source for us               |
| `File`/`POSIX`/`Windows` | raw stdin/stdout handles (platform `#if`)           |

We get a Jai tokenizer *for free* from the stdlib. That means semantic tokens, brace
matching, lexer-level diagnostics, and a first pass at symbol extraction don't require
writing a lexer.

---

## Project structure

```
jai-lsp/
  build.jai              # build metaprogram (#run build())
  src/
    main.jai             # entry point; owns the read/dispatch loop
    rpc.jai              # framing: read_message(), write_message(); header parse
    json.jai             # jaison glue: decode envelope, decode params-by-method
    protocol.jai         # LSP type structs (see below)
    server.jai           # Server state, dispatch table, lifecycle handlers
    documents.jai        # Document store (URI -> text + version + line index)
    analysis.jai         # Jai-specific intelligence built on Jai_Lexer
    log.jai              # stderr/file logging (NEVER stdout)
  vscode-extension/
    package.json
    tsconfig.json
    src/extension.ts     # spawns jai-lsp over stdio
```

---

## Protocol types (`protocol.jai`)

jaison maps JSON to Jai structs by field name via reflection, so we declare the LSP
shapes we care about as plain structs. Start small — only what each milestone needs.

```jai
Position :: struct {
    line:      int;   // 0-based
    character: int;   // 0-based, UTF-16 code units (see gotcha #3)
}

Range :: struct {
    start: Position;
    end:   Position;
}

Location :: struct {
    uri:   string;
    range: Range;
}

// Lifecycle response payload
Server_Capabilities :: struct {
    textDocumentSync:        int = 1;   // 1 = full document sync
    hoverProvider:           bool = true;
    documentSymbolProvider:  bool;
    definitionProvider:      bool;
    completionProvider:      *Completion_Options; // null until M4
}
```

**Heterogeneous `params` pattern.** The `params` field differs per method, so we
can't decode the whole message into one fixed struct. Two-step decode:

1. Decode the *envelope* to read `id` (may be absent) and `method`.
2. Switch on `method`, then decode `params` into the method-specific struct.

```jai
// pseudocode shape — confirm exact jaison proc names against your version
Envelope :: struct {
    jsonrpc: string;
    id:      *int;     // pointer => optional; null for notifications
    method:  string;
    // params decoded separately, per method
}
```

> **Confirm against your jaison version:** the exact decode/encode entry points
> (`json_parse_string`, `json_write_*`, generic value type name) drift between
> distributions. Nail these in M0 and document the real signatures right here.

---

## Memory model

- **Per message:** parse, build the response, then `reset_temporary_storage()` at the
  bottom of each loop iteration. All JSON scratch and `tprint` output is transient.
- **Persistent:** the document store and (later) the symbol index live in a long-lived
  allocator — heap, or a `Pool` we never reset. Document text must outlive the message
  that opened it.
- Loop sketch:

```jai
while server.running {
    msg, ok := read_message();      // blocks on stdin
    if !ok  break;
    handle_message(*server, msg);   // may write_message()
    reset_temporary_storage();      // free all per-message scratch
}
```

---

## Milestones

### M0 — Skeleton (de-risk the plumbing first)
- stdin read loop + `Content-Length` framing (`rpc.jai`).
- Handle `initialize` → reply with `Server_Capabilities`.
- Handle `initialized` (notification, no reply), `shutdown`, `exit`.
- Logging to stderr.
- **Done when:** VSCode connects and the server logs a clean handshake. No language
  features yet — just a living connection.

### M1 — Text sync + stub hover
- `textDocument/didOpen` / `didChange` (full sync) / `didClose` → maintain the store.
- Maintain a per-document line-start index (byte offset of each line) for fast
  position↔offset conversion.
- `textDocument/hover` → return the identifier under the cursor (echo). Proves the
  position math and the request/response round trip end to end.

### M2 — Tokens + diagnostics (first real Jai intelligence)
- Run `Jai_Lexer` over document text.
- Emit semantic tokens (keywords, strings, numbers, comments, identifiers).
- Push `textDocument/publishDiagnostics` for lexer-level errors (unterminated string,
  bad char, etc.).

### M3 — Document symbols
- Scan the token stream for top-level `name :: proc`, `name :: struct`, `name :: enum`,
  and constant declarations → `textDocument/documentSymbol` outline.

### M4 — Definition + completion
- Build a workspace symbol index (walk `.jai` files; `File_Utilities.visit_files`).
- `textDocument/definition` resolves identifier → declaration site.
- `textDocument/completion` offers symbols + keywords in scope.

Each milestone is shippable on its own. Don't start M(n+1) until M(n) round-trips in a
real editor.

---

## Known gotchas (read before coding)

1. **stdout is the wire.** Any stray `print` corrupts the protocol. Route all logging
   to stderr/file. On Windows, ensure stdout is in **binary mode** so `\n` isn't
   translated to `\r\n` — otherwise byte counts in `Content-Length` won't match.

2. **Read exactly N bytes.** stdin reads can return short. Loop until you've read the
   full `Content-Length`, or you'll desync the stream and never recover.

3. **Positions are UTF-16 code units, not bytes or codepoints.** This is *the* classic
   LSP footgun. A `Position.character` is a UTF-16 offset into the line. Since Jai
   strings are UTF-8 bytes, you must convert UTF-16 columns ↔ byte offsets for any line
   containing non-ASCII. Build this conversion into `documents.jai` early; retrofitting
   it is painful. (You may advertise `positionEncoding: "utf-8"` in `initialize` if the
   client supports it — check the client capability and prefer UTF-8 when offered.)

4. **Notifications get no response.** Branch on presence of `id` before writing
   anything back.

5. **Optional fields.** Model "may be absent" JSON fields as pointers (`*int`,
   `*string`) so null/missing is representable. Confirm how your jaison build signals
   absent vs null.

6. **Lazarus order.** `shutdown` (request) should flip a flag and reply; `exit`
   (notification) actually terminates. Exiting on `shutdown` is wrong.

---

## VSCode extension (the thin shim)

`vscode-extension/src/extension.ts` — the entire integration:

```ts
import { workspace, ExtensionContext } from "vscode";
import { LanguageClient, ServerOptions, TransportKind } from "vscode-languageclient/node";

let client: LanguageClient;

export function activate(_ctx: ExtensionContext) {
  const serverOptions: ServerOptions = {
    command: "/absolute/path/to/jai-lsp",   // the compiled Jai binary
    transport: TransportKind.stdio,
  };
  client = new LanguageClient(
    "jai-lsp",
    "Jai Language Server",
    serverOptions,
    { documentSelector: [{ scheme: "file", language: "jai" }] },
  );
  client.start();
}

export function deactivate() {
  return client?.stop();
}
```

`package.json` needs to (a) declare the `jai` language id with `.jai` file extension,
(b) set `main` to the compiled extension, (c) list `vscode-languageclient` as a dep.
For dev iteration, point `command` at the binary directly; for distribution, bundle the
binary per-platform and resolve its path at runtime.

---

## Build & run

```bash
# Server
jai src/main.jai                 # produces ./jai-lsp (configure name in build.jai)
jai build.jai                    # if/when we drive the build via metaprogram

# VSCode extension
cd vscode-extension
npm install
npm run compile                  # tsc
# then F5 in VSCode to launch an Extension Development Host
```

Smoke test the server without an editor by piping a framed `initialize` message into it
and checking the framed reply on stdout.

---

## Open questions / decide as we go

- **Incremental sync (M5+)?** Start with full-document sync (capability `1`). Move to
  incremental (`2`) only if large files lag.
- **Parser vs lexer-only.** M2–M4 ride on the lexer. Real go-to-definition across
  scopes and type-aware completion eventually want a parser/AST. Defer until lexer-based
  features are solid.
- **positionEncoding negotiation.** Prefer UTF-8 when the client advertises support to
  sidestep gotcha #3 entirely; fall back to UTF-16 conversion otherwise.
