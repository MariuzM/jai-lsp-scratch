# Jai LSP Scratch

A language server for the [Jai programming language](https://youtube.com/user/jblow888), written in
Jai itself, with a VS Code extension.

> ⚠️ **Experimental project.** Built and tested against a leaked, outdated build of the Jai compiler
> — not the current closed beta. Newer compiler versions of compiler might not work with this, until i can access i cant test and update.

## Features

- **Go to definition** — workspace symbols, locals and parameters, enum members (`.MEMBER`), `#load`
  / `#import` targets, and symbols from imported compiler modules (`trim`, `array_add`, ...)
- **Find all references** — word-boundary search across the workspace, live editor buffers included
- **Hover** — declaration signature and origin (`src/http.jai:168` or `Jai/String/module.jai:928`)
- **Completion** — all indexed declarations, including imported modules
- **Document / workspace symbols**
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

### What it formats

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

Requires a Jai compiler (closed beta) on PATH, plus `node`/`npm` for packaging (and `watchexec` for `make dev`). First time: `cd extension && npm install`.

```
make build      # compile the server -> server/build/jai-lsp-scratch
make dev        # rebuild on every change under server/ (watchexec)
make bundle     # build + copy the binary into extension/bin/
make package    # bundle + produce the .vsix
make install    # package + install the .vsix into VS Code
make release    # package + create/refresh the GitHub release for the current version
make clean      # remove build artifacts and .vsix files
```

All build artifacts (executable, dSYM, intermediates) go to `server/build/` — `server/build.jai` is a metaprogram that sets `output_path` and `intermediate_path`.

Dev loop: set `jaiLspScratch.serverPath` to `<repo>/server/build/jai-lsp-scratch`, run `make dev`, and reload the VS Code window after each rebuild — no reinstall needed. Clear the setting to go back to the bundled binary.

## Credits

The TextMate grammar (`extension/syntaxes/`) comes from
[The-Language](https://github.com/onelivesleft/The-Language) by onelivesleft, MIT licensed.
