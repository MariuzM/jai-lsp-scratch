# Jai LSP Scratch

A language server for the [Jai programming language](https://youtube.com/user/jblow888), written in
Jai itself, with a VS Code extension.

> ⚠️ **Experimental project.** Built and tested against a leaked, outdated build of the Jai compiler
> — not the current closed beta. Newer compiler versions might not work with this; until I can
> access one, I can't test and update.

## Features

- **Go to definition** — workspace symbols, locals and parameters, enum members (`.MEMBER`), `#load`
  / `#import` targets, and symbols from imported compiler modules (`trim`, `array_add`, ...)
- **Find all references** — word-boundary search across the workspace, live editor buffers included
- **Hover** — declaration signature and origin (`src/http.jai:168` or `Jai/String/module.jai:928`)
- **Completion with auto-import** — all indexed declarations, including symbols from common compiler
  modules you haven't imported yet: completions show their module (`Basic — print :: ...`) and
  accepting one automatically inserts `#import "Basic";` after your existing imports (or at the top
  of the file)
- **Document / workspace symbols**
- **Semantic highlighting** — identifiers known to the index are colored by what they are: `enum`,
  `struct`, `enumMember`, `function` — so a type like `Token_Type` gets your theme's enum color at
  every use site, not just its declaration
- **Diagnostics** — runs the Jai compiler on your entry file (auto-detected via `main ::`) on save
  and surfaces errors inline
- **Formatter** — see below

The server is index-based (a fast lexer pass, no type inference), so it is instant but approximate:
symbols with the same name in multiple enums/files resolve to all candidates.

## Formatter

The formatter follows the conventions used in the Jai compiler's own `modules/` sources (the
alignment rules were derived by measuring them: 55% of constant groups, 64% of field groups, and 62%
of inline-case groups there are column-aligned, always padded to the longest name + 1 space).

Before:

```jai
WORKER_COUNT :: 64;
MAX_BODY_SIZE :: 96 * 1024 * 1024;
libvips :: #library "../lib/libvips";
vips_error_clear :: () #foreign libvips;
vips_image_get_width :: (image: *VipsImage) -> s32 #foreign libvips;



Pair :: struct {
    key: string;
    value: string;
}

handle :: (res: *Response, v: Json_Value) {
		data:= cast(*void) input.data;
size := cast(u64) input.count;
res.status = status;
    res.content_type = "application/json";
        res.body = body;
if v.kind == {
case .STRING; kind_ok = v.kind == .STRING;
case .INTEGER; kind_ok = v.kind == .INTEGER;
}
}
```

After:

```jai
WORKER_COUNT         :: 64;
MAX_BODY_SIZE        :: 96 * 1024 * 1024;
libvips              :: #library "../lib/libvips";
vips_error_clear     :: () #foreign libvips;
vips_image_get_width :: (image: *VipsImage) -> s32 #foreign libvips;

Pair :: struct {
    key:   string;
    value: string;
}

handle :: (res: *Response, v: Json_Value) {
    data := cast(*void) input.data;
    size := cast(u64) input.count;
    res.status       = status;
    res.content_type = "application/json";
    res.body         = body;
    if v.kind == {
        case .STRING;  kind_ok = v.kind == .STRING;
        case .INTEGER; kind_ok = v.kind == .INTEGER;
    }
}
```

### More examples

Single-line `if` bodies get the `then` keyword so the boundary between condition and body is
explicit:

```jai
// before
if !last_closed_transparent  opaque_depth -= 1;
if !ok  return;
if cond  a += 1; b += 1;    // trap: b += 1 runs unconditionally!

// after
if !last_closed_transparent then opaque_depth -= 1;
if !ok then return;
if cond then a += 1;
b += 1;
```

Short `if` / `else` bodies collapse onto one line when the result is simple and fits 100 columns:

```jai
// before
if cond {
    a += 1;
    b += 1;
}

// after
if cond { a += 1; b += 1; }
```

Bodies stay multi-line when the collapsed form would exceed 100 characters, or when they contain
nested blocks, control flow, comments, or blank lines.

A second statement after an inline `if` always moves to its own line, because in Jai the `if` (with
or without `then`) governs only the first statement — the split makes the real behavior visible:

```jai
// before
if x > 5 then y += 1; z += 1;    // z += 1 runs ALWAYS, even when x <= 5

// after
if x > 5 then y += 1;
z += 1;
```

Unbraced chains become `then` chains; chains written with braces keep them and align their blocks
after the longest condition:

```jai
parse_digit :: (c: u8) -> s32 {
    if c >= #char "0" && c <= #char "9" then return c - #char "0";
    else if c >= #char "a" && c <= #char "f" then return c - #char "a" + 10;
    else return -1;
}

resolve :: (link: string, path: string) -> string {
    if link[0] == #char "/" { result = copy_string(link); }
    else                    { result = tprint("%/%", dir_of(path), link); }
    return result;
}
```

Enum members with values and inline `case` bodies:

```jai
Token_Kind :: enum {
    IDENT  :: 256;
    NUMBER :: 257;
    STRING :: 258;
}

describe :: (t: Token_Kind) -> string {
    if t == {
        case .IDENT;  return "identifier";
        case .NUMBER; return "number";
        case;         return "other";
    }
}
```

`:=` declarations, including multi-return lvalues:

```jai
email        := json_get_string(root, "email");
password     := json_get_string(root, "password");
age, has_age := json_get(root, "age");
```

### What it formats

**Statement layout**

- One statement per line: code after an opening `{` moves to the next line (when the block spans
  multiple lines), and multiple `;`-terminated statements on one line are split apart — this also
  disambiguates traps like `if cond  a; b;` where `b;` runs unconditionally
- Single-line `if` / `else if` bodies get the `then` keyword: `if cond  stmt;` becomes
  `if cond then stmt;` (bare `else  stmt;` becomes `else stmt;`); single-line `while` / `for` bodies
  are braced (`while x > 0  step();` becomes `while x > 0 { step(); }`). When sloppy spacing makes
  the condition/body boundary ambiguous, the line is only cleaned, never restructured
- Short `if` / `else` bodies collapse to one line (`if cond { a += 1; b += 1; }`) when the result
  fits 100 columns and the body is simple statements only; longer or complex bodies stay multi-line
- Single-statement `then` lines you write yourself are kept as-is (spacing normalized); extra
  statements after the `if`'s first `;` always split onto their own line

**Global whitespace cleanup**

- Runs of extra spaces anywhere in code collapse to a single space (`x   :=  f(a,    b);` becomes
  `x := f(a, b);`) — string contents, comment text, and here-strings are untouched
- Trailing `//` comments get exactly two spaces before them
- Cleanup runs first; the alignment rules below then re-create every deliberate column, so stale
  hand-padding disappears while intentional alignment is rebuilt

**Indentation & whitespace**

- 4-space indentation from brace/paren/bracket depth; tabs in leading whitespace are replaced
- `case` bodies on following lines get one extra level; nested blocks inside a case carry it through
- Continuation lines inside multi-line calls indent one level, even when several parens open on the
  same line (`send_json(res, tprint(` counts once)
- Trailing whitespace stripped; file ends with exactly one newline
- Blank-line runs collapse to a single blank line; leading/trailing blank lines are removed

**Column alignment** (groups of 2+ consecutive declarations at the same indent, `::`/`:`/`=`/`:=`
padded to the longest name + 1):

- `::` declarations of any kind that fit on one line — constants, `#foreign` bindings, `#library` /
  `#import` lines
- Struct/enum fields and typed declarations: `name: type;` (also normalizes `name : type` to
  `name: type`)
- Assignments: `lvalue = expr;`
- Variable declarations: `name := value;`, including multi-return `value, ok := ...`
- Inline `case` bodies: `case .X;  statement;`
- Single-line `if` / `else if` / `else` chains: braced bodies align one space after the longest
  condition, with `else` branches padded to the same column

A blank line (or any non-matching line) separates groups — use one to keep two neighbors from
aligning together.

**HTML here-strings**

- Content of `#string HTML` here-strings is re-indented by tag nesting depth (4 spaces per level) —
  indentation only, the markup itself is never changed
- `<style>` / `<script>` contents are kept flat at one level; void tags (`<meta>`, `<img>`, `<br>`,
  ...), self-closing tags, doctype, and comments don't open a level
- Here-strings with any other terminator (`#string DONE`, ...) remain completely untouched

**Never touched**

- Anything inside strings, `#string` here-strings (except `#string HTML` indentation, above), and
  block comments
- Spacing inside a line beyond the alignment rules above (hand-formatting survives)
- Multi-line declarations (`proc :: (…) {`, `X :: struct {`) — only single-line `;`-terminated
  declarations align

## Performance

Measured on an M-series Mac against two workspaces: a small real project (~1.4k lines, ~17k
declarations including imported compiler modules) and a large stress-test workspace built from real
Jai code (3 copies of the compiler's `modules/` tree: **1,627 files / 1,030,552 lines / 332,440
declarations**). Latencies are medians of repeated requests against the same running server.

### Small project (~17k declarations)

| Operation      | Latency |
| -------------- | ------- |
| definition     | 0.2 ms  |
| hover          | ~1 ms   |
| references     | 2 ms    |
| semanticTokens | 1.9 ms  |
| formatting     | 3.5 ms  |
| completion     | 17 ms   |

### 1M-line workspace (332k declarations)

What holds up:

| Operation                            | Latency | Notes                            |
| ------------------------------------ | ------- | -------------------------------- |
| definition / hover                   | 1.6 ms  |                                  |
| documentSymbol (13,620-line file)    | 1.2 ms  |                                  |
| didChange reindex (small file)       | 4.6 ms  | per keystroke                    |
| didChange reindex (13,620-line file) | 109 ms  | typing in giant files lags a bit |
| semanticTokens (13,620-line file)    | 64 ms   | debounced by the editor          |
| formatting (13,620-line file)        | 159 ms  | save-time only                   |

Known limits at this scale:

| Problem    | Measured                    | Cause                                                                                                                        |
| ---------- | --------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| completion | 463 ms, 332k items (~60 MB) | every declaration is sent on every request — needs server-side prefix filtering with `isIncomplete`                          |
| references | 1.9 s                       | re-reads all workspace files from disk per request — needs the file-content cache we already build during indexing           |
| memory     | ~655 MB RSS                 | ~2 KB per declaration (per-decl heap copies of path/signature/completion JSON) — path interning would cut this substantially |
| startup    | 41.8 s                      | single-threaded lex + index of 1M lines, one-time per window                                                                 |

Below ~100k lines none of these limits are noticeable; on a typical project every request is
effectively instant.

## Future improvements

Concrete changes to come back to, roughly in order of impact.

**Performance at scale** (each maps to a measured limit above)

- [ ] **Completion: server-side filtering.** Match items against the word being typed, return the
      best ~1,000 with `isIncomplete: true` so the editor re-queries as you type. Fixes the
      463 ms / 60 MB response on huge workspaces and shrinks the 17 ms on normal ones. The
      per-declaration JSON fragments are already precomputed, so this is a filter loop in
      `handle_completion`.
- [ ] **References: in-memory file cache.** `scan_workspace` already reads every file once and
      throws the text away; keeping it (~35 MB per 1M lines) turns the per-request disk sweep
      (1.9 s) into an in-memory scan. Needs invalidation from `didChange`/`didSave` only.
- [ ] **Memory: intern per-file strings.** Every declaration heap-copies its `path`; one shared
      copy per file would cut a large slice of the ~2 KB/decl footprint. Same idea for dropping
      `signature` where `completion_base` already embeds it.
- [ ] **Startup: parallel or lazy indexing.** 41.8 s for 1M lines is single-threaded lexing; the
      Thread module could fan out per-file indexing, or module indexing could become lazy
      (index a module on first lookup miss instead of at startup).

**Resolution quality**

- [ ] **Scope-aware lookups.** Definition and semantic tokens are name-based; a local variable
      sharing a name with an indexed type gets the type's color and definition. Preferring the
      nearest enclosing local declaration would fix both.
- [ ] **Platform-aware definitions.** Symbols defined per-OS (`generated_linux.jai`,
      `generated_windows.jai`, ...) return all variants; the current platform's file should rank
      first.
- [ ] **Signature help** (`textDocument/signatureHelp`) while typing call arguments — the index
      already stores full signatures.
- [ ] **Rename** (`textDocument/rename`) — the references machinery already finds all edit sites.

**Protocol & plumbing**

- [ ] **Incremental sync.** The server requests full-document sync; every keystroke ships the
      whole file. `TextDocumentSyncKind.Incremental` would cut didChange traffic on big files
      (the 109 ms reindex of a 13k-line file includes receiving all of it).
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

The extension bundles a prebuilt server binary (macOS arm64; more platforms as they get built). No
further setup is needed for navigation features.

For **diagnostics**, the server needs your Jai compiler. It tries `jai` on PATH; if that doesn't
resolve, set:

```json
"jaiLspScratch.compilerPath": "/path/to/jai/bin/jai-macos"
```

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

All build artifacts (executable, dSYM, intermediates) go to `server/build/` — `server/build.jai` is
a metaprogram that sets `output_path` and `intermediate_path`.

Dev loop: set `jaiLspScratch.serverPath` to `<repo>/server/build/jai-lsp-scratch`, run `make dev`,
and reload the VS Code window after each rebuild — no reinstall needed. Clear the setting to go back
to the bundled binary.

## Credits

The TextMate grammar (`extension/syntaxes/`) comes from
[The-Language](https://github.com/onelivesleft/The-Language) by onelivesleft, MIT licensed.
