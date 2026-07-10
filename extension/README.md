# Jai LSP Scratch

A language server for the [Jai programming language](https://youtube.com/user/jblow888), written in Jai itself, with a VS Code extension.

> ⚠️ **Experimental project.** Built and tested against a leaked, outdated build of the Jai compiler — not the current closed beta. Newer compiler versions may lex/format/diagnose differently, and no compatibility is guaranteed.

## Features

- **Go to definition** — workspace symbols, locals and parameters, enum members (`.MEMBER`), `#load` / `#import` targets, and symbols from imported compiler modules (`trim`, `array_add`, ...)
- **Find all references** — word-boundary search across the workspace, live editor buffers included
- **Hover** — declaration signature and origin (`src/http.jai:168` or `Jai/String/module.jai:928`)
- **Completion** — all indexed declarations, including imported modules
- **Document / workspace symbols**
- **Diagnostics** — runs the Jai compiler on your entry file (auto-detected via `main ::`) on save and surfaces errors inline
- **Formatter** — whitespace normalization (4-space indent, `case` bodies, continuation lines) plus column alignment for `::` constant groups, struct fields, `=` assignments, `:=` declarations, and inline `case` bodies, following the conventions of the compiler's own modules; collapses multiple blank lines

The server is index-based (a fast lexer pass, no type inference), so it is instant but approximate: symbols with the same name in multiple enums/files resolve to all candidates.

## Install

Download the `.vsix` from [Releases](../../releases) and install it:

```
code --install-extension jai-lsp-scratch-<version>.vsix
```

or in VS Code: Extensions panel → `...` menu → *Install from VSIX...*

The extension bundles a prebuilt server binary (macOS arm64; more platforms as they get built). No further setup is needed for navigation features.

For **diagnostics**, the server needs your Jai compiler. It tries `jai` on PATH; if that doesn't resolve, set:

```json
"jaiLspScratch.compilerPath": "/path/to/jai/bin/jai-macos"
```

## Settings

| Setting | Default | Description |
|---|---|---|
| `jaiLspScratch.serverPath` | *(bundled)* | Path to a jai-lsp server binary, overrides the bundled one |
| `jaiLspScratch.compilerPath` | `jai` on PATH | Jai compiler used for diagnostics |

## Building from source

Requires a Jai compiler (closed beta).

```
cd server
jai main.jai -exe jai-lsp-scratch
cp jai-lsp-scratch ../extension/bin/jai-lsp-scratch-<platform>-<arch>
cd ../extension
npm install
npx @vscode/vsce package
```

## Credits

The TextMate grammar (`extension/syntaxes/`) comes from [The-Language](https://github.com/onelivesleft/The-Language) by onelivesleft, MIT licensed.
