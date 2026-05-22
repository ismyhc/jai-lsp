// End-to-end smoke test for jai-lsp.
//
// Spawns ./jai-lsp once per session, drives a scripted JSON-RPC dialog over
// stdio, and asserts that the framed responses look right. Covers:
//
//   Session 1: handshake (initialize / initialized / shutdown / exit)
//   Session 2: utf-16 default — didOpen → hover (ASCII) → didChange → hover → didClose
//   Session 3: utf-8 negotiated — capabilities reflect it, hover honors byte offsets
//   Session 4: non-ASCII document with utf-16 — position math survives multi-byte chars
//
// Run with:  bun test/smoke.ts
// Exits non-zero on any failure.

const BIN = new URL("../jai-lsp", import.meta.url).pathname;

function frame(jsonObj: unknown): Buffer {
    const body = Buffer.from(JSON.stringify(jsonObj), "utf-8");
    return Buffer.concat([
        Buffer.from(`Content-Length: ${body.length}\r\n\r\n`, "ascii"),
        body,
    ]);
}

function tryReadFrame(buf: Buffer): { body: unknown; consumed: number } | null {
    const headerEnd = buf.indexOf("\r\n\r\n");
    if (headerEnd < 0) return null;
    const headers = buf.subarray(0, headerEnd).toString("ascii");
    const m = headers.match(/Content-Length:\s*(\d+)/i);
    if (!m) throw new Error(`No Content-Length: ${JSON.stringify(headers)}`);
    const len = parseInt(m[1], 10);
    const bodyStart = headerEnd + 4;
    if (buf.length < bodyStart + len) return null;
    return {
        body: JSON.parse(buf.subarray(bodyStart, bodyStart + len).toString("utf-8")),
        consumed: bodyStart + len,
    };
}

type Msg = unknown;
type SessionResult = {
    responses: Record<number, any>;       // request id -> response body
    notifications: any[];                  // server-initiated, in order
    stderr: string;
    exitCode: number;
};
async function runSession(messages: Msg[]): Promise<SessionResult> {
    const proc = Bun.spawn([BIN], { stdin: "pipe", stdout: "pipe", stderr: "pipe" });
    for (const m of messages) proc.stdin.write(frame(m));
    await proc.stdin.end();

    const stdoutBytes = await new Response(proc.stdout).bytes();
    const stderr = await new Response(proc.stderr).text();
    const exitCode = await proc.exited;

    const responses: Record<number, any> = {};
    const notifications: any[] = [];
    let cursor = Buffer.from(stdoutBytes);
    while (cursor.length > 0) {
        const next = tryReadFrame(cursor);
        if (!next) break;
        const msg = next.body as any;
        if (msg && typeof msg === "object" && "id" in msg) {
            responses[msg.id] = msg;
        } else {
            notifications.push(msg);
        }
        cursor = cursor.subarray(next.consumed);
    }
    return { responses, notifications, stderr, exitCode };
}

let failed = 0;
function check(name: string, cond: boolean, detail?: string) {
    if (cond) {
        console.log(`  ✓ ${name}`);
    } else {
        console.log(`  ✗ ${name}${detail ? ` — ${detail}` : ""}`);
        failed += 1;
    }
}

function dumpOnFailure(label: string, info: SessionResult) {
    console.error(`\n=== ${label} stderr ===\n${info.stderr}`);
    console.error(`\n=== ${label} responses ===\n${JSON.stringify(info.responses, null, 2)}`);
    console.error(`\n=== ${label} notifications ===\n${JSON.stringify(info.notifications, null, 2)}`);
}

const INIT = (extraCaps: Record<string, unknown> = {}) => ({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
        processId: null,
        rootUri: null,
        capabilities: { general: extraCaps },
    },
});
const INITIALIZED = { jsonrpc: "2.0", method: "initialized", params: {} };
const SHUTDOWN    = { jsonrpc: "2.0", id: 999, method: "shutdown" };
const EXIT        = { jsonrpc: "2.0", method: "exit" };

// --- Session 1: handshake ---------------------------------------------------
console.log("Session 1: handshake");
{
    const before = failed;
    const r = await runSession([INIT(), INITIALIZED, SHUTDOWN, EXIT]);
    const init = r.responses[1];
    check("initialize response present", !!init);
    check("initialize has result",       !!init?.result);
    check("capabilities present",        !!init?.result?.capabilities);
    check("hoverProvider=true",          init?.result?.capabilities?.hoverProvider === true);
    check("semanticTokensProvider present", !!init?.result?.capabilities?.semanticTokensProvider);
    check("legend tokenTypes nonempty",  (init?.result?.capabilities?.semanticTokensProvider?.legend?.tokenTypes?.length ?? 0) > 0);
    check("default positionEncoding utf-16", init?.result?.capabilities?.positionEncoding === "utf-16");
    const shut = r.responses[999];
    check("shutdown response present",   !!shut);
    check("shutdown result=null",        shut?.result === null);
    check("clean exit",                  r.exitCode === 0);
    if (failed > before) dumpOnFailure("Session 1", r);
}

// --- Session 2: didOpen / hover / didChange / hover / didClose (utf-16 default)
console.log("\nSession 2: text sync + hover (utf-16 default)");
{
    const before = failed;
    const uri = "file:///tmp/foo.jai";
    const text1 = "foo := 42\nbar :: greet\n";
    const text2 = "hello :: 1\n";
    const r = await runSession([
        INIT(),  // no positionEncodings → defaults to utf-16
        INITIALIZED,
        { jsonrpc: "2.0", method: "textDocument/didOpen", params: {
            textDocument: { uri, languageId: "jai", version: 1, text: text1 },
        }},
        { jsonrpc: "2.0", id: 10, method: "textDocument/hover", params: {
            textDocument: { uri }, position: { line: 0, character: 0 },
        }},
        { jsonrpc: "2.0", id: 11, method: "textDocument/hover", params: {
            textDocument: { uri }, position: { line: 1, character: 7 },
        }},
        { jsonrpc: "2.0", method: "textDocument/didChange", params: {
            textDocument: { uri, version: 2 },
            contentChanges: [{ text: text2 }],
        }},
        { jsonrpc: "2.0", id: 12, method: "textDocument/hover", params: {
            textDocument: { uri }, position: { line: 0, character: 2 },
        }},
        { jsonrpc: "2.0", method: "textDocument/didClose", params: { textDocument: { uri } } },
        SHUTDOWN, EXIT,
    ]);
    check("hover 'foo'",   r.responses[10]?.result?.contents?.value === "`foo`",   `got ${JSON.stringify(r.responses[10]?.result)}`);
    check("hover 'greet'", r.responses[11]?.result?.contents?.value === "`greet`", `got ${JSON.stringify(r.responses[11]?.result)}`);
    check("hover 'hello'", r.responses[12]?.result?.contents?.value === "`hello`", `got ${JSON.stringify(r.responses[12]?.result)}`);
    check("clean exit",    r.exitCode === 0);
    if (failed > before) dumpOnFailure("Session 2", r);
}

// --- Session 3: utf-8 negotiated --------------------------------------------
console.log("\nSession 3: utf-8 negotiation");
{
    const before = failed;
    const uri = "file:///tmp/bar.jai";
    const text = "foo := 42\n";
    const r = await runSession([
        INIT({ positionEncodings: ["utf-8", "utf-16"] }),
        INITIALIZED,
        { jsonrpc: "2.0", method: "textDocument/didOpen", params: {
            textDocument: { uri, languageId: "jai", version: 1, text },
        }},
        { jsonrpc: "2.0", id: 20, method: "textDocument/hover", params: {
            textDocument: { uri }, position: { line: 0, character: 0 },
        }},
        SHUTDOWN, EXIT,
    ]);
    check("negotiated positionEncoding=utf-8", r.responses[1]?.result?.capabilities?.positionEncoding === "utf-8");
    check("hover still resolves",              r.responses[20]?.result?.contents?.value === "`foo`");
    check("clean exit",                        r.exitCode === 0);
    if (failed > before) dumpOnFailure("Session 3", r);
}

// --- Session 4: non-ASCII content with utf-16 --------------------------------
console.log("\nSession 4: utf-16 with multi-byte chars");
{
    const before = failed;
    const uri = "file:///tmp/baz.jai";
    const text = "α := beta\n";
    const r = await runSession([
        INIT(),
        INITIALIZED,
        { jsonrpc: "2.0", method: "textDocument/didOpen", params: {
            textDocument: { uri, languageId: "jai", version: 1, text },
        }},
        { jsonrpc: "2.0", id: 30, method: "textDocument/hover", params: {
            textDocument: { uri }, position: { line: 0, character: 5 },
        }},
        SHUTDOWN, EXIT,
    ]);
    check("utf-16 position lands on 'beta'", r.responses[30]?.result?.contents?.value === "`beta`",
        `got ${JSON.stringify(r.responses[30]?.result)}`);
    check("clean exit",                       r.exitCode === 0);
    if (failed > before) dumpOnFailure("Session 4", r);
}

// --- Session 5: semantic tokens (clean file) --------------------------------
console.log("\nSession 5: semantic tokens");
{
    const before = failed;
    const uri = "file:///tmp/tokens.jai";
    // Mix of declarations and bare references. Per the new policy, only
    // confident classifications get a semantic token:
    //   * keywords / strings / numbers — always
    //   * IDENT that is a top-level decl in THIS file — function/struct/enum
    //   * IDENT that is a bare reference (variable, cross-file call, etc.) —
    //     NOT tokenized; the TextMate grammar handles it
    const text =
`Vec :: struct {\n    x: float;\n}\n` +
`greet :: () {\n    return;\n}\n` +
`bar :: "hi"\n` +
`if mystery then x = 1\n`;
    const r = await runSession([
        INIT(),
        INITIALIZED,
        { jsonrpc: "2.0", method: "textDocument/didOpen", params: {
            textDocument: { uri, languageId: "jai", version: 1, text },
        }},
        { jsonrpc: "2.0", id: 40, method: "textDocument/semanticTokens/full", params: {
            textDocument: { uri },
        }},
        SHUTDOWN, EXIT,
    ]);
    const init = r.responses[1];
    const legend: string[] = init?.result?.capabilities?.semanticTokensProvider?.legend?.tokenTypes ?? [];
    const idxKeyword  = legend.indexOf("keyword");
    const idxString   = legend.indexOf("string");
    const idxNumber   = legend.indexOf("number");
    const idxFunction = legend.indexOf("function");
    const idxStruct   = legend.indexOf("struct");
    check("legend has keyword/string/number/function/struct",
        idxKeyword >= 0 && idxString >= 0 && idxNumber >= 0 && idxFunction >= 0 && idxStruct >= 0);

    const data: number[] = r.responses[40]?.result?.data ?? [];
    check("token data nonempty",         data.length > 0);
    check("token data is multiple of 5", data.length % 5 === 0, `len=${data.length}`);

    const decoded: { line: number; col: number; len: number; type: number }[] = [];
    let line = 0, col = 0;
    for (let i = 0; i < data.length; i += 5) {
        const [dl, ds, len, t] = [data[i], data[i+1], data[i+2], data[i+3]];
        if (dl !== 0) { line += dl; col = ds; } else { col += ds; }
        decoded.push({ line, col, len, type: t });
    }
    const find = (line: number, col: number) => decoded.find(d => d.line === line && d.col === col);

    // Declarations we expect to be semantically classified.
    check("Vec at (0,0) is struct len 3",      find(0, 0)?.type === idxStruct   && find(0, 0)?.len === 3);
    check("greet at (3,0) is function len 5",  find(3, 0)?.type === idxFunction && find(3, 0)?.len === 5);

    // Always-confident token types.
    check("'hi' string emitted",  decoded.some(d => d.type === idxString));
    check("'if' keyword emitted", decoded.some(d => d.type === idxKeyword));

    // Bare identifier `mystery` (unknown) and `x` (variable) should NOT be tokenized.
    check("'mystery' not tokenized", !find(6, 3));   // line 6 (0-based), col 3 after "if "
    check("'x' not tokenized",       !find(6, 15));  // approximate; relaxed below

    // Belt-and-suspenders: no token slot should claim type==undefined.
    check("every token has a valid type slot", decoded.every(d => d.type >= 0 && d.type < legend.length));

    check("clean exit", r.exitCode === 0);
    if (failed > before) dumpOnFailure("Session 5", r);
}

// --- Session 6b: documentSymbol ---------------------------------------------
console.log("\nSession 6b: documentSymbol");
{
    const before = failed;
    const uri = "file:///tmp/symbols.jai";
    // Mix of top-level kinds plus a nested decl that should NOT appear at the top level.
    const text =
`PI :: 3.14
greet :: () {
    helper :: () { }
}
Vec :: struct {
    x: float;
}
Color :: enum {
    RED;
    GREEN;
}
Flags :: enum_flags { A; B; }
`;
    const r = await runSession([
        INIT(),
        INITIALIZED,
        { jsonrpc: "2.0", method: "textDocument/didOpen", params: {
            textDocument: { uri, languageId: "jai", version: 1, text },
        }},
        { jsonrpc: "2.0", id: 50, method: "textDocument/documentSymbol", params: {
            textDocument: { uri },
        }},
        SHUTDOWN, EXIT,
    ]);
    const syms: any[] = r.responses[50]?.result ?? [];

    // SymbolKind constants (per LSP spec)
    const SK_FUNCTION = 12, SK_CONSTANT = 14, SK_ENUM = 10, SK_STRUCT = 23;

    const byName = Object.fromEntries(syms.map((s: any) => [s.name, s]));
    check("documentSymbolProvider=true in caps", r.responses[1]?.result?.capabilities?.documentSymbolProvider === true);
    check("five top-level symbols",  syms.length === 5, `got ${syms.length}: ${syms.map((s:any)=>s.name).join(",")}`);
    check("PI is constant",          byName.PI?.kind === SK_CONSTANT);
    check("greet is function",       byName.greet?.kind === SK_FUNCTION);
    check("Vec is struct",           byName.Vec?.kind === SK_STRUCT);
    check("Color is enum",           byName.Color?.kind === SK_ENUM);
    check("Flags is enum",           byName.Flags?.kind === SK_ENUM);
    check("helper not at top level", !("helper" in byName));
    check("PI selectionRange is line 0",   byName.PI?.selectionRange?.start?.line === 0);
    check("greet selectionRange is line 1",byName.greet?.selectionRange?.start?.line === 1);
    check("Vec selectionRange is line 4",  byName.Vec?.selectionRange?.start?.line === 4);
    check("clean exit",              r.exitCode === 0);
    if (failed > before) dumpOnFailure("Session 6b", r);
}

// --- Session 7: multi-file definition + completion --------------------------
console.log("\nSession 7: multi-file workspace, definition + completion");
{
    const before = failed;

    // Build a tiny workspace on disk.
    const fs = await import("node:fs/promises");
    const os = await import("node:os");
    const path = await import("node:path");
    const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "jai-lsp-ws-"));
    await fs.writeFile(path.join(tmpDir, "math.jai"),
        `add :: (a: int, b: int) -> int { return a + b; }\n` +
        `PI :: 3.14\n`);
    await fs.writeFile(path.join(tmpDir, "shapes.jai"),
        `Circle :: struct {\n    radius: float;\n}\n`);
    const callerPath = path.join(tmpDir, "main.jai");
    const callerText =
        `main :: () {\n` +
        `    c := add(1, 2);\n` +
        `    r := PI;\n` +
        `    s: Circle;\n` +
        `}\n`;
    await fs.writeFile(callerPath, callerText);

    const callerUri = `file://${callerPath}`;
    const rootUri   = `file://${tmpDir}`;

    const initWithRoot = {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
            processId: null,
            rootUri,
            capabilities: { general: {} },
        },
    };

    // Positions in `main.jai`:
    //   "    c := add(1, 2);"   → `add` is at line 1, character 9 (after "    c := ")
    //   "    r := PI;"          → `PI`  is at line 2, character 9
    //   "    s: Circle;"        → `Circle` is at line 3, character 7
    const r = await runSession([
        initWithRoot,
        INITIALIZED,
        { jsonrpc: "2.0", method: "textDocument/didOpen", params: {
            textDocument: { uri: callerUri, languageId: "jai", version: 1, text: callerText },
        }},
        { jsonrpc: "2.0", id: 70, method: "textDocument/definition", params: {
            textDocument: { uri: callerUri }, position: { line: 1, character: 9 },
        }},
        { jsonrpc: "2.0", id: 71, method: "textDocument/definition", params: {
            textDocument: { uri: callerUri }, position: { line: 2, character: 9 },
        }},
        { jsonrpc: "2.0", id: 72, method: "textDocument/definition", params: {
            textDocument: { uri: callerUri }, position: { line: 3, character: 7 },
        }},
        { jsonrpc: "2.0", id: 73, method: "textDocument/completion", params: {
            textDocument: { uri: callerUri }, position: { line: 4, character: 0 },
        }},
        SHUTDOWN, EXIT,
    ]);

    // Cleanup the temp dir up front so a test failure doesn't leak files.
    try { await fs.rm(tmpDir, { recursive: true, force: true }); } catch {}

    check("init advertises definitionProvider", r.responses[1]?.result?.capabilities?.definitionProvider === true);
    check("init advertises completionProvider", !!r.responses[1]?.result?.capabilities?.completionProvider);

    const def_add: any[] = r.responses[70]?.result ?? [];
    check("definition(add) returns one location",  def_add.length === 1);
    check("definition(add) points to math.jai",   (def_add[0]?.uri ?? "").endsWith("/math.jai"));
    check("definition(add) on line 0",             def_add[0]?.range?.start?.line === 0);

    const def_pi: any[] = r.responses[71]?.result ?? [];
    check("definition(PI) returns one location",  def_pi.length === 1);
    check("definition(PI) points to math.jai",   (def_pi[0]?.uri ?? "").endsWith("/math.jai"));
    check("definition(PI) on line 1",             def_pi[0]?.range?.start?.line === 1);

    const def_circle: any[] = r.responses[72]?.result ?? [];
    check("definition(Circle) returns one location",  def_circle.length === 1);
    check("definition(Circle) points to shapes.jai", (def_circle[0]?.uri ?? "").endsWith("/shapes.jai"));
    check("definition(Circle) on line 0",             def_circle[0]?.range?.start?.line === 0);

    const completion = r.responses[73]?.result;
    const labels: string[] = (completion?.items ?? []).map((it: any) => it.label);
    check("completion includes 'add'",    labels.includes("add"));
    check("completion includes 'PI'",     labels.includes("PI"));
    check("completion includes 'Circle'", labels.includes("Circle"));
    check("completion includes keyword 'if'", labels.includes("if"));
    check("clean exit",                   r.exitCode === 0);
    if (failed > before) dumpOnFailure("Session 7", r);
}

// --- Session 8: workspace/symbol search -------------------------------------
console.log("\nSession 8: workspace/symbol search");
{
    const before = failed;
    const fs = await import("node:fs/promises");
    const os = await import("node:os");
    const path = await import("node:path");
    const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "jai-lsp-ws-"));
    await fs.writeFile(path.join(tmpDir, "math.jai"),
        `add :: (a: int, b: int) -> int { return a + b; }\n` +
        `subtract :: (a: int, b: int) -> int { return a - b; }\n` +
        `Adder :: struct { x: int; }\n`);
    const rootUri = `file://${tmpDir}`;

    const initWithRoot = {
        jsonrpc: "2.0", id: 1, method: "initialize",
        params: { processId: null, rootUri, capabilities: { general: {} } },
    };

    const r = await runSession([
        initWithRoot,
        INITIALIZED,
        { jsonrpc: "2.0", id: 80, method: "workspace/symbol", params: { query: "add" } },
        { jsonrpc: "2.0", id: 81, method: "workspace/symbol", params: { query: "ADD" } },     // case-insensitive
        { jsonrpc: "2.0", id: 82, method: "workspace/symbol", params: { query: "" } },        // everything
        { jsonrpc: "2.0", id: 83, method: "workspace/symbol", params: { query: "zzznope" } }, // nothing
        SHUTDOWN, EXIT,
    ]);
    try { await fs.rm(tmpDir, { recursive: true, force: true }); } catch {}

    check("workspaceSymbolProvider=true", r.responses[1]?.result?.capabilities?.workspaceSymbolProvider === true);

    const r80: any[] = r.responses[80]?.result ?? [];
    const names80 = r80.map(s => s.name).sort();
    check("query 'add' hits add + Adder", JSON.stringify(names80) === JSON.stringify(["Adder", "add"]),
        `got ${JSON.stringify(names80)}`);

    const r81: any[] = r.responses[81]?.result ?? [];
    check("query 'ADD' is case-insensitive", r81.length === 2);

    const r82: any[] = r.responses[82]?.result ?? [];
    const names82 = r82.map(s => s.name).sort();
    check("empty query returns all 3 symbols",
        JSON.stringify(names82) === JSON.stringify(["Adder", "add", "subtract"]),
        `got ${JSON.stringify(names82)}`);

    const r83: any[] = r.responses[83]?.result ?? [];
    check("no-match query returns []", r83.length === 0);

    const hit = r80.find(s => s.name === "add");
    check("location has uri + range", !!hit?.location?.uri && !!hit?.location?.range);
    check("location uri points to math.jai", (hit?.location?.uri ?? "").endsWith("/math.jai"));
    check("kind is set on result", typeof hit?.kind === "number");
    check("clean exit", r.exitCode === 0);
    if (failed > before) dumpOnFailure("Session 8", r);
}

// --- Session 9: folding ranges ----------------------------------------------
console.log("\nSession 9: folding ranges");
{
    const before = failed;
    const uri = "file:///tmp/folds.jai";
    // Lines:
    //   0  foo :: () {
    //   1      bar :: () {
    //   2          x := 1;
    //   3      }
    //   4  }
    //   5  Vec :: struct {
    //   6      x: float;
    //   7  }
    //   8  inline_block :: () { return; }   // single line — no fold
    const text =
`foo :: () {
    bar :: () {
        x := 1;
    }
}
Vec :: struct {
    x: float;
}
inline_block :: () { return; }
`;
    const r = await runSession([
        INIT(),
        INITIALIZED,
        { jsonrpc: "2.0", method: "textDocument/didOpen", params: {
            textDocument: { uri, languageId: "jai", version: 1, text },
        }},
        { jsonrpc: "2.0", id: 90, method: "textDocument/foldingRange", params: {
            textDocument: { uri },
        }},
        SHUTDOWN, EXIT,
    ]);
    check("foldingRangeProvider=true", r.responses[1]?.result?.capabilities?.foldingRangeProvider === true);

    const ranges: any[] = r.responses[90]?.result ?? [];
    // Expect three folds: foo (0..3), nested bar (1..2), Vec (5..6).
    // The single-line `inline_block` is too short to fold.
    const norm = ranges.map(r => `${r.startLine}-${r.endLine}`).sort();
    const want = ["0-3", "1-2", "5-6"].sort();
    check("3 folds at the expected line spans",
        JSON.stringify(norm) === JSON.stringify(want),
        `got ${JSON.stringify(norm)}`);
    check("clean exit", r.exitCode === 0);
    if (failed > before) dumpOnFailure("Session 9", r);
}

// --- Session 10: find all references ----------------------------------------
console.log("\nSession 10: find all references");
{
    const before = failed;
    const fs = await import("node:fs/promises");
    const os = await import("node:os");
    const path = await import("node:path");
    const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "jai-lsp-refs-"));
    await fs.writeFile(path.join(tmpDir, "math.jai"),
        `add :: (a: int, b: int) -> int { return a + b; }\n`);                  // line 0: decl
    await fs.writeFile(path.join(tmpDir, "use1.jai"),
        `main :: () { x := add(1, 2); }\n`);                                    // line 0: ref
    const callerPath = path.join(tmpDir, "use2.jai");
    const callerText =
        `helper :: () {\n` +
        `    y := add(3, 4);\n` +    // line 1: ref
        `    z := add(5, 6);\n` +    // line 2: ref
        `}\n`;
    await fs.writeFile(callerPath, callerText);

    const rootUri  = `file://${tmpDir}`;
    const useUri   = `file://${callerPath}`;

    const initWithRoot = {
        jsonrpc: "2.0", id: 1, method: "initialize",
        params: { processId: null, rootUri, capabilities: { general: {} } },
    };

    const r = await runSession([
        initWithRoot,
        INITIALIZED,
        { jsonrpc: "2.0", method: "textDocument/didOpen", params: {
            textDocument: { uri: useUri, languageId: "jai", version: 1, text: callerText },
        }},
        // Cursor on `add` inside use2.jai line 1. includeDeclaration=true.
        { jsonrpc: "2.0", id: 100, method: "textDocument/references", params: {
            textDocument: { uri: useUri }, position: { line: 1, character: 9 },
            context: { includeDeclaration: true },
        }},
        // Same cursor, but excluding the declaration.
        { jsonrpc: "2.0", id: 101, method: "textDocument/references", params: {
            textDocument: { uri: useUri }, position: { line: 1, character: 9 },
            context: { includeDeclaration: false },
        }},
        SHUTDOWN, EXIT,
    ]);
    try { await fs.rm(tmpDir, { recursive: true, force: true }); } catch {}

    check("referencesProvider=true", r.responses[1]?.result?.capabilities?.referencesProvider === true);

    const all_refs: any[] = r.responses[100]?.result ?? [];
    // Expect 4 hits: 1 decl in math.jai, 1 ref in use1.jai, 2 refs in use2.jai.
    check("4 references including decl", all_refs.length === 4, `got ${all_refs.length}: ${JSON.stringify(all_refs)}`);
    const inMath = all_refs.filter(l => l.uri.endsWith("/math.jai"));
    const inUse1 = all_refs.filter(l => l.uri.endsWith("/use1.jai"));
    const inUse2 = all_refs.filter(l => l.uri.endsWith("/use2.jai"));
    check("1 hit in math.jai (decl)", inMath.length === 1);
    check("1 hit in use1.jai",        inUse1.length === 1);
    check("2 hits in use2.jai",       inUse2.length === 2);

    const no_decl: any[] = r.responses[101]?.result ?? [];
    check("3 references excluding decl", no_decl.length === 3);
    const noDeclInMath = no_decl.filter(l => l.uri.endsWith("/math.jai"));
    check("decl is excluded from math.jai", noDeclInMath.length === 0);
    check("clean exit", r.exitCode === 0);
    if (failed > before) dumpOnFailure("Session 10", r);
}

// --- Session 11: file watcher (didChangeWatchedFiles) -----------------------
console.log("\nSession 11: file watcher");
{
    const before = failed;
    const fs = await import("node:fs/promises");
    const os = await import("node:os");
    const path = await import("node:path");
    const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "jai-lsp-watch-"));
    const fooPath = path.join(tmpDir, "foo.jai");
    await fs.writeFile(fooPath, `original_sym :: 1\n`);
    const fooUri = `file://${fooPath}`;
    const rootUri = `file://${tmpDir}`;

    // We'll let the server scan, then modify the file on disk, fire a
    // didChangeWatchedFiles notification, and check the workspace symbol
    // search picks up the new name and forgets the old one.
    const initWithRoot = {
        jsonrpc: "2.0", id: 1, method: "initialize",
        params: { processId: null, rootUri, capabilities: { general: {} } },
    };

    // Rewrite the file BEFORE sending the watcher event — the server will
    // re-read from disk when it processes the notification.
    const modify = async () => {
        await fs.writeFile(fooPath, `replaced_sym :: 2\n`);
    };

    // We can't really synchronize "modify after scan" inside a single runSession
    // call (messages are sent before stdin closes). Workaround: send a small
    // pause via a no-op request to push past the scan, then assume disk write
    // is done. Simpler: just write the new contents BEFORE the watcher event
    // — the server processes messages in order, so by the time it handles
    // didChangeWatchedFiles, our rewrite has landed.
    await modify();

    const r = await runSession([
        initWithRoot,
        INITIALIZED,
        // First confirm post-scan state: `original_sym` should NOT be there
        // (we overwrote the file before scan, so the scan reads `replaced_sym`).
        // Actually scan runs on `initialized` — by then we've already
        // overwritten. So scan picks up `replaced_sym`. Let's verify that
        // first, then fire a delete and confirm purge.
        { jsonrpc: "2.0", id: 110, method: "workspace/symbol", params: { query: "replaced_sym" } },
        { jsonrpc: "2.0", method: "workspace/didChangeWatchedFiles", params: {
            changes: [{ uri: fooUri, type: 3 /* Deleted */ }],
        }},
        // Server side: process the deletion, then we query again.
        { jsonrpc: "2.0", id: 111, method: "workspace/symbol", params: { query: "replaced_sym" } },
        SHUTDOWN, EXIT,
    ]);

    // Cleanup before assertions so a failure doesn't leak the dir.
    try { await fs.rm(tmpDir, { recursive: true, force: true }); } catch {}

    const r110: any[] = r.responses[110]?.result ?? [];
    check("scan picked up replaced_sym",       r110.some(s => s.name === "replaced_sym"));
    const r111: any[] = r.responses[111]?.result ?? [];
    check("delete event purged replaced_sym",  r111.length === 0,
        `got ${JSON.stringify(r111)}`);
    check("clean exit", r.exitCode === 0);
    if (failed > before) dumpOnFailure("Session 11", r);
}

// --- Session 12: signature help ---------------------------------------------
console.log("\nSession 12: signature help");
{
    const before = failed;
    const fs = await import("node:fs/promises");
    const os = await import("node:os");
    const path = await import("node:path");
    const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "jai-lsp-sig-"));
    await fs.writeFile(path.join(tmpDir, "math.jai"),
        `add :: (a: int, b: int) -> int { return a + b; }\n` +
        `clamp :: (x: float, lo: float, hi: float) -> float { return x; }\n`);
    const callerPath = path.join(tmpDir, "main.jai");
    const callerText =
        `main :: () {\n` +
        `    x := add(1, 2);\n` +              // line 1, simple call
        `    y := clamp(0.5, 0.0, 1.0);\n` +   // line 2
        `}\n`;
    await fs.writeFile(callerPath, callerText);

    const callerUri = `file://${callerPath}`;
    const rootUri   = `file://${tmpDir}`;

    const initWithRoot = {
        jsonrpc: "2.0", id: 1, method: "initialize",
        params: { processId: null, rootUri, capabilities: { general: {} } },
    };

    // Positions inside `add(1, 2)`:
    //   "    x := add("   ← cursor at 14 = right after `(` → param 0
    //   "    x := add(1, "← cursor at 17 = right after `, ` → param 1
    // Positions inside `clamp(0.5, 0.0, 1.0)`:
    //   "    y := clamp(0.5, 0.0, "  ← cursor at 26 → param 2
    const r = await runSession([
        initWithRoot,
        INITIALIZED,
        { jsonrpc: "2.0", method: "textDocument/didOpen", params: {
            textDocument: { uri: callerUri, languageId: "jai", version: 1, text: callerText },
        }},
        { jsonrpc: "2.0", id: 120, method: "textDocument/signatureHelp", params: {
            textDocument: { uri: callerUri }, position: { line: 1, character: 14 },
        }},
        { jsonrpc: "2.0", id: 121, method: "textDocument/signatureHelp", params: {
            textDocument: { uri: callerUri }, position: { line: 1, character: 17 },
        }},
        { jsonrpc: "2.0", id: 122, method: "textDocument/signatureHelp", params: {
            textDocument: { uri: callerUri }, position: { line: 2, character: 26 },
        }},
        SHUTDOWN, EXIT,
    ]);
    try { await fs.rm(tmpDir, { recursive: true, force: true }); } catch {}

    check("signatureHelpProvider present", !!r.responses[1]?.result?.capabilities?.signatureHelpProvider);

    const sh1 = r.responses[120]?.result;
    check("add( signature returned", !!sh1?.signatures?.length, `got ${JSON.stringify(sh1)}`);
    check("add( label contains '(a: int, b: int)'",
        (sh1?.signatures?.[0]?.label ?? "").includes("(a: int, b: int)"),
        `got label=${JSON.stringify(sh1?.signatures?.[0]?.label)}`);
    check("add( activeParameter=0",   sh1?.activeParameter === 0);
    check("add has 2 parameters",     sh1?.signatures?.[0]?.parameters?.length === 2);

    const sh2 = r.responses[121]?.result;
    check("add(1,  activeParameter=1", sh2?.activeParameter === 1);

    const sh3 = r.responses[122]?.result;
    check("clamp signature returned", !!sh3?.signatures?.length);
    check("clamp activeParameter=2",   sh3?.activeParameter === 2);
    check("clamp has 3 parameters",    sh3?.signatures?.[0]?.parameters?.length === 3);

    check("clean exit", r.exitCode === 0);
    if (failed > before) dumpOnFailure("Session 12", r);
}

// --- Session 13: AST-backed hover + typeDefinition + inlay hints ------------
// Requires the Jai compiler reachable via JAI_COMPILER env. Skips otherwise.
if (!process.env.JAI_COMPILER) {
    console.log("\nSession 13: SKIPPED (JAI_COMPILER not set)");
} else {
    console.log("\nSession 13: AST-backed hover, typeDefinition, inlay hints");
    const before = failed;
    const fs = await import("node:fs/promises");
    const os = await import("node:os");
    const path = await import("node:path");
    const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "jai-lsp-ast-"));
    const file = path.join(tmpDir, "ast.jai");
    const text =
`#import "Basic";

Vec :: struct {
    x: float;
    y: float;
}

add :: (a: int, b: int) -> int { return a + b; }

main :: () {
    v: Vec;
    sum := add(1, 2);
    print("%\\n", sum);
}
`;
    await fs.writeFile(file, text);
    const uri = `file://${file}`;
    const rootUri = `file://${tmpDir}`;

    const r = await runSession([
        { jsonrpc: "2.0", id: 1, method: "initialize",
          params: { processId: null, rootUri, capabilities: { general: {} } } },
        INITIALIZED,
        { jsonrpc: "2.0", method: "textDocument/didOpen", params: {
            textDocument: { uri, languageId: "jai", version: 1, text }
        }},
        // Trigger a check — synchronous; by the next request, AST is loaded.
        { jsonrpc: "2.0", method: "textDocument/didSave", params: { textDocument: { uri } } },
        // Hover on `add` at line 7 character 0 (the decl)
        { jsonrpc: "2.0", id: 130, method: "textDocument/hover", params: {
            textDocument: { uri }, position: { line: 7, character: 0 }
        }},
        // Hover on `Vec` at line 2 character 0
        { jsonrpc: "2.0", id: 131, method: "textDocument/hover", params: {
            textDocument: { uri }, position: { line: 2, character: 0 }
        }},
        // typeDefinition on `v` (line 10, `    v: Vec;`) — should jump to Vec
        { jsonrpc: "2.0", id: 132, method: "textDocument/typeDefinition", params: {
            textDocument: { uri }, position: { line: 10, character: 4 }
        }},
        // Inlay hints across the document
        { jsonrpc: "2.0", id: 133, method: "textDocument/inlayHint", params: {
            textDocument: { uri }, range: { start: { line: 0, character: 0 }, end: { line: 14, character: 0 } }
        }},
        SHUTDOWN, EXIT,
    ]);
    try { await fs.rm(tmpDir, { recursive: true, force: true }); } catch {}

    check("typeDefinitionProvider=true", r.responses[1]?.result?.capabilities?.typeDefinitionProvider === true);
    check("inlayHintProvider=true",       r.responses[1]?.result?.capabilities?.inlayHintProvider === true);

    const hover_add: any = r.responses[130]?.result;
    check("hover(add) returns markdown",  hover_add?.contents?.kind === "markdown");
    check("hover(add) includes signature",
        ((hover_add?.contents?.value ?? "") as string).includes("add ::") &&
        ((hover_add?.contents?.value ?? "") as string).includes("s64"),
        `got ${JSON.stringify(hover_add?.contents?.value)}`);

    const hover_vec: any = r.responses[131]?.result;
    check("hover(Vec) labels as struct",
        ((hover_vec?.contents?.value ?? "") as string).includes("Vec :: struct"),
        `got ${JSON.stringify(hover_vec?.contents?.value)}`);

    const type_def: any[] = r.responses[132]?.result ?? [];
    check("typeDefinition(v) returns a Location", type_def.length >= 1,
        `got ${JSON.stringify(type_def)}`);
    check("typeDefinition(v) points to ast.jai", (type_def[0]?.uri ?? "").endsWith("/ast.jai"));
    check("typeDefinition(v) line is Vec's line (2)", type_def[0]?.range?.start?.line === 2);

    const hints: any[] = r.responses[133]?.result ?? [];
    const sum_hint = hints.find((h: any) => h?.label?.includes("s64") || h?.label?.includes("int"));
    check("inlay hint for `sum` includes its type", !!sum_hint,
        `got ${JSON.stringify(hints)}`);

    check("clean exit", r.exitCode === 0);
    if (failed > before) dumpOnFailure("Session 13", r);
}

// --- Session 6: diagnostics on a bad file -----------------------------------
console.log("\nSession 6: lex-level diagnostics");
{
    const before = failed;
    const uri = "file:///tmp/bad.jai";
    const text = `x := "unterminated\n`;   // string literal with no closing quote
    const r = await runSession([
        INIT(),
        INITIALIZED,
        { jsonrpc: "2.0", method: "textDocument/didOpen", params: {
            textDocument: { uri, languageId: "jai", version: 1, text },
        }},
        SHUTDOWN, EXIT,
    ]);
    const diag = r.notifications.find(n => n?.method === "textDocument/publishDiagnostics" && n?.params?.uri === uri);
    check("publishDiagnostics arrived",     !!diag);
    check("at least one diagnostic",        (diag?.params?.diagnostics?.length ?? 0) > 0,
        `got ${JSON.stringify(diag?.params?.diagnostics)}`);
    check("diagnostic has range + message", !!diag?.params?.diagnostics?.[0]?.range && !!diag?.params?.diagnostics?.[0]?.message);
    check("clean exit",                     r.exitCode === 0);
    if (failed > before) dumpOnFailure("Session 6", r);
}

console.log(failed === 0 ? "\nALL OK" : `\nFAILED: ${failed} check(s)`);
process.exit(failed === 0 ? 0 : 1);
