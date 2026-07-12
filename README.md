# Jai LSP Scratch

A language server for the [Jai programming language](https://youtube.com/user/jblow888), written in
Jai itself, with a VS Code extension.

> ⚠️ **Experimental project.** Built and tested against a leaked, outdated build of the Jai compiler
> — not the current closed beta. Newer compiler versions might not work with this; until I can
> access one, I can't test and update.

## Features

- **Go to definition** — workspace symbols, locals and parameters, enum members (`.MEMBER`), `#load`
  / `#import` targets, and symbols from imported compiler modules
- **Find all references** — word-boundary search across the workspace, live editor buffers included
- **Hover** — declaration signature and origin
- **Completion with auto-import** — accepting a symbol from a module you haven't imported inserts
  the `#import` line for you
- **Document / workspace symbols**
- **Semantic highlighting** — identifiers colored by what they are (`enum`, `struct`, `enumMember`,
  `function`) at every use site
- **Diagnostics** — runs the Jai compiler on your entry file on save and surfaces errors inline
- **Formatter** — every rule shown below, with real output

The server is index-based (a fast lexer pass, no type inference), so it is instant but approximate.

## Formatter

Every example below is actual formatter output. All alignment rules work on groups of 2+ consecutive
matching lines at the same indent; a blank line (or any non-matching line) breaks the group, so use
one to keep two neighbors from aligning together.

### 1. Indentation and statement layout

4-space indentation derived from brace/paren/bracket nesting. Tabs and sloppy leading whitespace are
replaced; trailing whitespace is stripped; blank-line runs collapse to one.

Before:

```jai
handle :: (res: *Response, v: Json_Value) {
		data:= cast(*void) input.data;
size := cast(u64) input.count;
res.status = status;
    res.content_type = "application/json";
        res.body = body;
}
```

After:

```jai
handle :: (res: *Response, v: Json_Value) {
    data := cast(*void) input.data;
    size := cast(u64) input.count;
    res.status       = status;
    res.content_type = "application/json";
    res.body         = body;
}
```

### 2. Whitespace cleanup

Runs of spaces inside code collapse to a single space; trailing `//` comments get exactly two
spaces. Strings, comment text, and here-strings are untouched.

Before:

```jai
x   :=  f(a,    b);
y := g(c);     // trailing comment
```

After:

```jai
x := f(a, b);
y := g(c);  // trailing comment
```

### 3. Constant alignment

Consecutive `::` constants align on the `::`, padded to the longest name + 1.

```jai
WORKER_COUNT  :: 64;
MAX_BODY_SIZE :: 96 * 1024 * 1024;
DEFAULT_PORT  :: 8080;
```

### 4. Foreign binding alignment

Foreign procedure declarations align twice: on the `::` and on the trailing `#foreign` directive.

```jai
pthread_self       :: () -> pthread_t                            #foreign libc;
pthread_getname_np :: (p: pthread_t, name: *u8, len: u64) -> s32 #foreign libc;
pthread_setname_np :: (name: *u8) -> s32                         #foreign libc;
```

### 5. Struct and enum field alignment

`name: type;` fields align on the type; `name : type` is normalized to `name: type`.

```jai
Pair :: struct {
    key:   string;
    value: string;
    hits:  s64;
}
```

### 6. Variable declaration alignment

`:=` declarations align, including multi-return lvalues.

```jai
email        := json_get_string(root, "email");
password     := json_get_string(root, "password");
age, has_age := json_get(root, "age");
```

### 7. Assignment alignment

Plain `=` assignments align on the `=`.

```jai
res.status       = status;
res.content_type = "application/json";
res.body         = body;
```

### 8. Inline `case` alignment

Inline case bodies align after the longest case label.

```jai
describe :: (t: Token_Kind) -> string {
    if t == {
        case .IDENT;  return "identifier";
        case .NUMBER; return "number";
        case;         return "other";
    }
}
```

### 9. Braced `if` / `else` chain alignment

Single-line braced chains align their blocks one space after the longest condition.

```jai
resolve :: (link: string, path: string) -> string {
    if link[0] == #char "/" { result = copy_string(link); }
    else                    { result = tprint("%/%", dir_of(path), link); }
    return result;
}
```

### 10. Inline `if` with `return` / `break` / `continue`

When the body of an inline `if` is a jump statement, it stays bare (no `then`, no braces) and
consecutive guards align after the longest condition. A stray `then` before a jump (including ones
inserted by older versions of this formatter) is removed.

Before:

```jai
format_bytes :: (b: float64) -> string {
    if b < 1024 return tprint("% B", b);
    if b < 1024 * 1024 then return tprint("% KB", b / 1024.0);
    if b < 1024 * 1024 * 1024 return tprint("% MB", b / (1024.0 * 1024.0));
    return tprint("% GB", b / (1024.0 * 1024.0 * 1024.0));
}
```

After:

```jai
format_bytes :: (b: float64) -> string {
    if b < 1024               return tprint("% B", b);
    if b < 1024 * 1024        return tprint("% KB", b / 1024.0);
    if b < 1024 * 1024 * 1024 return tprint("% MB", b / (1024.0 * 1024.0));
    return tprint("% GB", b / (1024.0 * 1024.0 * 1024.0));
}
```

### 11. `then` for other inline `if` bodies

Any other single-line `if` body gets the `then` keyword so the condition/body boundary is explicit.
A second statement after the `;` always moves to its own line, because the `if` only governs the
first statement — the split makes the real behavior visible.

Before:

```jai
if !last_closed_transparent  opaque_depth -= 1;
if x > 5 then y += 1; z += 1;    // z += 1 runs ALWAYS, even when x <= 5
```

After:

```jai
if !last_closed_transparent then opaque_depth -= 1;
if x > 5 then y += 1;
z += 1;
```

### 12. Braces for inline loops

Single-line `while` / `for` bodies are wrapped in braces. Write the braces yourself and the body can
hold any number of statements inline — it is kept as-is. Without braces the loop only governs the
first statement, so anything after the first `;` is split onto its own line to make that visible.

Before:

```jai
while x > 0  step();
while x > 0 { x -= 1; total += x; }
for 1..count  advance(); emit(it);    // trap: emit(it) runs AFTER the loop, once
```

After:

```jai
while x > 0 { step(); }
while x > 0 { x -= 1; total += x; }
for 1..count { advance(); }
emit(it);  // trap: emit(it) runs AFTER the loop, once
```

### 13. Imports move to the top

All top-level `#import` and `#load` statements are hoisted to the top of the file (after a leading
file comment, if any), in their original order, followed by a blank line. Imports inside `#string`
blocks or nested in `#if` braces stay where they are.

Before:

```jai
main :: () {
    print("hi");
}

#import "Basic";
#load "http.jai";
```

After:

```jai
#import "Basic";
#load "http.jai";

main :: () {
    print("hi");
}
```

### 14. HTML here-string indentation

The content of `#string HTML` here-strings is re-indented by tag nesting depth — indentation only,
the markup itself is never changed. Void tags, self-closing tags, doctype, and comments don't open a
level; `<style>` / `<script>` contents stay flat. Here-strings with any other terminator remain
completely untouched.

Before:

```jai
PAGE :: #string HTML
<html>
<head>
<meta charset="utf-8">
</head>
<body>
<div class="row">
<p>Hello</p>
</div>
</body>
</html>
HTML
```

After:

```jai
PAGE :: #string HTML
<html>
    <head>
        <meta charset="utf-8">
    </head>
    <body>
        <div class="row">
            <p>Hello</p>
        </div>
    </body>
</html>
HTML
```

### 15. Never touched

- Anything inside strings, `#string` here-strings (except `#string HTML` indentation, above), and
  block comments
- Spacing inside a line beyond the rules above — hand-formatting survives
- Multi-line declarations (`proc :: (…) {`, `X :: struct {`) — only single-line `;`-terminated
  declarations align

Formatting is idempotent: running the formatter on its own output changes nothing.

## Future improvements

Concrete changes to come back to, roughly in order of impact.

**Performance at scale** (measured on a 1M-line / 332k-declaration stress workspace)

- [ ] **Completion: server-side filtering.** Match items against the word being typed, return the
      best ~1,000 with `isIncomplete: true` so the editor re-queries as you type. Fixes the 463 ms /
      60 MB response on huge workspaces and shrinks the 17 ms on normal ones. The per-declaration
      JSON fragments are already precomputed, so this is a filter loop in `handle_completion`.
- [ ] **References: in-memory file cache.** `scan_workspace` already reads every file once and
      throws the text away; keeping it (~35 MB per 1M lines) turns the per-request disk sweep (1.9
      s) into an in-memory scan. Needs invalidation from `didChange`/`didSave` only.
- [ ] **Memory: intern per-file strings.** Every declaration heap-copies its `path`; one shared copy
      per file would cut a large slice of the ~2 KB/decl footprint (~655 MB RSS at 1M lines). Same
      idea for dropping `signature` where `completion_base` already embeds it.
- [ ] **Startup: parallel or lazy indexing.** 41.8 s for 1M lines is single-threaded lexing; the
      Thread module could fan out per-file indexing, or module indexing could become lazy (index a
      module on first lookup miss instead of at startup).

**Resolution quality**

- [x] **Scope-aware lookups.** Semantic highlighting, go-to-definition, and hover are scope-aware:
      file-local declarations override workspace-wide name matches, and locals/parameters shadow
      indexed symbols while in scope — so a variable named the same as a procedure elsewhere
      resolves to the local declaration, not all candidates.
- [ ] **Platform-aware definitions.** Symbols defined per-OS (`generated_linux.jai`,
      `generated_windows.jai`, ...) return all variants; the current platform's file should rank
      first.
- [ ] **Signature help** (`textDocument/signatureHelp`) while typing call arguments — the index
      already stores full signatures.
- [ ] **Rename** (`textDocument/rename`) — the references machinery already finds all edit sites.

**Protocol & plumbing**

- [ ] **Incremental sync.** The server requests full-document sync; every keystroke ships the whole
      file. `TextDocumentSyncKind.Incremental` would cut didChange traffic on big files.
- [ ] **External file watching.** Edits made outside the editor (git checkout, generators) aren't
      reindexed until the file is opened; a `workspace/didChangeWatchedFiles` registration would
      cover this.
- [ ] **One version source.** The version string lives in both `package.json` and the server's
      `initialize` response; the build should inject it from one place.
- [ ] **More platform binaries.** Only darwin-arm64 is bundled; the compiler can target
      linux/windows, so `make bundle` could cross-compile the rest.

**Formatter**

- [ ] **Configurable rules.** Line width (currently 100), alignment toggles, and indent width are
      hardcoded; expose them via `initializationOptions` from extension settings.
- [ ] **Range formatting** (`textDocument/rangeFormatting`) so format-on-paste and format-selection
      work instead of whole-document only.

## Install

Download the `.vsix` from [Releases](../../releases) and install it:

```
code --install-extension jai-lsp-scratch-<version>.vsix
```

or in VS Code: Extensions panel → `...` menu → _Install from VSIX..._

The extension bundles a prebuilt server binary (macOS arm64). For **diagnostics**, the server needs
your Jai compiler — it tries `jai` on PATH; otherwise set `jaiLspScratch.compilerPath`.

## Settings

| Setting                      | Default       | Description                                                |
| ---------------------------- | ------------- | ---------------------------------------------------------- |
| `jaiLspScratch.serverPath`   | _(bundled)_   | Path to a jai-lsp server binary, overrides the bundled one |
| `jaiLspScratch.compilerPath` | `jai` on PATH | Jai compiler used for diagnostics                          |

## Building from source

Requires a Jai compiler (closed beta) on PATH, plus `node`/`npm` for packaging (and `watchexec` for
`make dev`). First time: `cd extension && npm install`.

```
make build      # compile the server -> server/build/jai-lsp-scratch
make dev        # rebuild on every change under server/src/ (watchexec)
make bundle     # build + copy the binary into extension/bin/
make package    # bundle + produce the .vsix
make install    # package + install the .vsix into VS Code
make release    # package + create/refresh the GitHub release for the current version
make clean      # remove build artifacts and .vsix files
```

Dev loop: set `jaiLspScratch.serverPath` to `<repo>/server/build/jai-lsp-scratch`, run `make dev`,
and reload the VS Code window after each rebuild — no reinstall needed.

## Credits

The TextMate grammar (`extension/syntaxes/`) comes from
[The-Language](https://github.com/onelivesleft/The-Language) by onelivesleft, MIT licensed.
