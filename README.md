# Jai LSP Scratch

A language server for the [Jai programming language](https://youtube.com/user/jblow888), written in
Jai itself, with a VS Code extension.

> ⚠️ **Experimental project.** Built and tested against a leaked, outdated build of the Jai compiler
> — not the current closed beta. Newer compiler versions of compiler might not work with this, until
> i can access i cant test and update.

## Features

- **Go to definition** — workspace symbols, locals and parameters, enum members (`.MEMBER`), `#load`
  / `#import` targets, and symbols from imported compiler modules (`trim`, `array_add`, ...)
- **Find all references** — word-boundary search across the workspace, live editor buffers included
- **Hover** — declaration signature and origin (`src/http.jai:168` or `Jai/String/module.jai:928`)
- **Completion** — all indexed declarations, including imported modules
- **Document / workspace symbols**
- **Semantic highlighting** — identifiers known to the index are colored by what they are:
  `enum`, `struct`, `enumMember`, `function` — so a type like `Token_Type` gets your theme's enum
  color at every use site, not just its declaration
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

Lines using the `then` keyword are kept inline exactly as written (spacing normalized) — `then` is
your explicit "leave this line alone" marker:

```jai
if x > 5 then y += 1; z += 1;    // stays on one line; note z += 1 is NOT inside the if
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
  `if cond then stmt;` (bare `else  stmt;` becomes `else stmt;`); single-line `while` / `for`
  bodies are braced
- Short `if` / `else` bodies collapse to one line (`if cond { a += 1; b += 1; }`) when the result
  fits 100 columns and the body is simple statements only; longer or complex bodies stay multi-line
- `if` / `else` lines using the `then` keyword are never split, wrapped, or restructured — only
  their spacing is normalized

**Global whitespace cleanup**

- Runs of extra spaces anywhere in code collapse to a single space (`x   :=  f(a,    b);`
  becomes `x := f(a, b);`) — string contents, comment text, and here-strings are untouched
- Trailing `//` comments get exactly two spaces before them
- Cleanup runs first; the alignment rules below then re-create every deliberate column, so stale
  hand-padding disappears while intentional alignment is rebuilt
- Single-line `while` / `for` bodies are braced like `if` bodies (`while x > 0  step();` becomes
  `while x > 0 { step(); }`); when sloppy spacing makes the condition/body boundary ambiguous, the
  line is only cleaned, never restructured

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

**Never touched**

- Anything inside strings, `#string` here-strings, and block comments
- Spacing inside a line beyond the alignment rules above (hand-formatting survives)
- Multi-line declarations (`proc :: (…) {`, `X :: struct {`) — only single-line `;`-terminated
  declarations align

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
make dev        # rebuild on every change under server/ (watchexec)
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
