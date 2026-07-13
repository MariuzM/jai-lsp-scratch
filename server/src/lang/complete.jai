Type_Ref :: struct {
    name:        string;
    array_depth: s64;
    ok:          bool;
}

enum_context_type :: (text: string, path: string, line: s64, character: s64) -> string {
    line_text := get_line(text, line);
    limit     := character;
    if limit > line_text.count { limit = line_text.count; }
    k := limit - 1;
    while k >= 0 && is_word_char(line_text[k]) { k -= 1; }
    if k < 0 || line_text[k] != #char "." { return ""; }
    p := k - 1;
    if p >= 0 {
        c := line_text[p];
        if is_word_char(c) || c == #char ")" || c == #char "]" || c == #char "\"" || c == #char "." { return ""; }
    }
    while p >= 0 && (line_text[p] == #char " " || line_text[p] == #char "\t") { p -= 1; }

    expr := "";
    if p >= 1 && line_text[p] == #char "=" && (line_text[p-1] == #char "=" || line_text[p-1] == #char "!") {
        expr = extract_expr(line_text, p - 2);
    } else if p >= 0 && line_text[p] == #char "=" {
        q := p - 1;
        if q >= 0 && line_text[q] == #char ":" { return ""; }
        if q >= 0 && (line_text[q] == #char "+" || line_text[q] == #char "-" || line_text[q] == #char "|" || line_text[q] == #char "&" || line_text[q] == #char "^") { q -= 1; }
        expr = extract_expr(line_text, q);
    } else if p >= 3 && slice(line_text, p - 3, 4) == "case" && (p - 4 < 0 || !is_word_char(line_text[p-4])) {
        expr = switch_expr_above(text, line);
    }
    if !expr { return ""; }

    ref := resolve_expr_ref(text, path, expr, cast(s32) line, cast(s32) character, 0);
    if !ref.ok || ref.array_depth != 0 { return ""; }
    for find_decls(ref.name) if it.kind == .ENUM { return ref.name; }
    return "";
}

#scope_file

extract_expr :: (s: string, end: s64) -> string {
    e := end;
    while e >= 0 && (s[e] == #char " " || s[e] == #char "\t") { e -= 1; }
    if e < 0 { return ""; }
    start  := e;
    bdepth := 0;
    while start >= 0 {
        c := s[start];
        if c == #char "]" { bdepth += 1; start -= 1; continue; }
        if c == #char "[" {
            if bdepth == 0 { break; }
            bdepth -= 1;
            start -= 1;
            continue;
        }
        if bdepth > 0 { start -= 1; continue; }
        if is_word_char(c) || c == #char "." { start -= 1; continue; }
        break;
    }
    return slice(s, start + 1, e - start);
}

switch_expr_above :: (text: string, line: s64) -> string {
    depth := 0;
    l     := line;
    steps := 0;
    while l > 0 && steps < 500 {
        l -= 1;
        steps += 1;
        lt := get_line(text, l);
        i  := lt.count - 1;
        while i >= 0 {
            c := lt[i];
            if c == #char "}" { depth += 1; }
            else if c == #char "{" {
                if depth == 0 {
                    before := trim(slice(lt, 0, i));
                    if before.count >= 2 && slice(before, before.count - 2, 2) == "==" {
                        return extract_expr(before, before.count - 3);
                    }
                    return "";
                }
                depth -= 1;
            }
            i -= 1;
        }
    }
    return "";
}

resolve_expr_ref :: (text: string, path: string, expr: string, line: s32, col: s32, depth: s64) -> Type_Ref {
    fail: Type_Ref;
    if depth > 8 { return fail; }
    parts := split(expr, ".");
    if parts.count == 0 { return fail; }

    base, base_groups := split_indexing(parts[0]);
    if !base { return fail; }
    ref := resolve_name_type(text, path, base, line, col, depth);
    ref = apply_indexing(ref, base_groups);
    if !ref.ok { return fail; }

    for i: 1..parts.count-1 {
        field, field_groups := split_indexing(parts[i]);
        if !field || ref.array_depth != 0 { return fail; }
        ref = struct_field_type(ref.name, field, depth);
        ref = apply_indexing(ref, field_groups);
        if !ref.ok { return fail; }
    }
    return ref;
}

split_indexing :: (part: string) -> string, s64 {
    end    := part.count;
    groups := 0;
    while end > 0 && part[end-1] == #char "]" {
        d := 1;
        i := end - 2;
        while i >= 0 && d > 0 {
            if part[i] == #char "]" { d += 1; }
            if part[i] == #char "[" { d -= 1; }
            i -= 1;
        }
        if d != 0 { return "", 0; }
        end = i + 1;
        groups += 1;
    }
    return slice(part, 0, end), groups;
}

apply_indexing :: (ref: Type_Ref, groups: s64) -> Type_Ref {
    result := ref;
    if !result.ok { return result; }
    result.array_depth -= groups;
    if result.array_depth < 0 { result.ok = false; }
    return result;
}

resolve_name_type :: (text: string, path: string, name: string, line: s32, col: s32, depth: s64) -> Type_Ref {
    fail: Type_Ref;
    found, hit := find_scoped_local(text, name, line, col);
    if found { return type_from_decl_line(text, path, name, hit.line, depth); }
    for find_decls(name) {
        if it.kind != .VARIABLE && it.kind != .CONSTANT { continue; }
        other_text, ok := get_text(it.path);
        if !ok { continue; }
        return type_from_decl_line(other_text, it.path, name, it.line, depth);
    }
    return fail;
}

type_from_decl_line :: (text: string, path: string, name: string, decl_line: s32, depth: s64) -> Type_Ref {
    fail: Type_Ref;
    line_text := get_line(text, decl_line);
    toks      := collect_tokens(line_text);
    i         := 0;
    while i < toks.count {
        t := toks[i];
        if t.type == .IDENT && t.name == name && (i == 0 || toks[i-1].type != cast(Token_Type) #char ".") {
            ordinal := 0;
            back    := i;
            while back >= 2 && toks[back-1].type == cast(Token_Type) #char "," && toks[back-2].type == .IDENT {
                back -= 2;
                ordinal += 1;
            }
            j := i;
            while j + 2 < toks.count && toks[j+1].type == cast(Token_Type) #char "," && toks[j+2].type == .IDENT { j += 2; }
            if j + 1 < toks.count && toks[j+1].type == cast(Token_Type) #char ":" {
                n := j + 2;
                if n < toks.count && toks[n].type == cast(Token_Type) #char "=" {
                    return type_from_rhs(text, path, toks, n + 1, ordinal, decl_line, depth);
                }
                if n < toks.count && toks[n].type == cast(Token_Type) #char ":" { return fail; }
                return parse_type_tokens(toks, n);
            }
        }
        i += 1;
    }
    return fail;
}

type_from_rhs :: (text: string, path: string, toks: []Tok, start: s64, ordinal: s64, decl_line: s32, depth: s64) -> Type_Ref {
    fail: Type_Ref;
    if start >= toks.count { return fail; }
    first := toks[start];
    if first.type == .KEYWORD_CAST {
        j := start + 1;
        while j < toks.count && toks[j].type != cast(Token_Type) #char "(" {
            if toks[j].type == cast(Token_Type) #char ";" { return fail; }
            j += 1;
        }
        if j >= toks.count { return fail; }
        return parse_type_tokens(toks, j + 1);
    }
    if first.type != .IDENT { return fail; }
    if start + 1 < toks.count && toks[start+1].type == cast(Token_Type) #char "(" {
        return proc_return_type(first.name, ordinal);
    }

    builder: String_Builder;
    bdepth := 0;
    j      := start;
    while j < toks.count {
        tt := toks[j].type;
        if tt == cast(Token_Type) #char "[" { bdepth += 1; append(*builder, "["); j += 1; continue; }
        if tt == cast(Token_Type) #char "]" {
            if bdepth == 0 { break; }
            bdepth -= 1;
            append(*builder, "]");
            j += 1;
            continue;
        }
        if bdepth > 0 { j += 1; continue; }
        if tt == .IDENT { append(*builder, toks[j].name); j += 1; continue; }
        if tt == cast(Token_Type) #char "." { append(*builder, "."); j += 1; continue; }
        break;
    }
    expr := builder_to_string(*builder);
    if !expr { return fail; }
    return resolve_expr_ref(text, path, expr, decl_line, 0, depth + 1);
}

proc_return_type :: (name: string, ordinal: s64) -> Type_Ref {
    fail: Type_Ref;
    for decl: find_decls(name) {
        if decl.kind != .PROCEDURE { continue; }
        arrow := find_index_from_left(decl.signature, "->");
        if arrow == -1 { continue; }
        rest := slice(decl.signature, arrow + 2, decl.signature.count - arrow - 2);
        toks := collect_tokens(rest);
        j    := 0;
        if j < toks.count && toks[j].type == cast(Token_Type) #char "(" { j += 1; }
        group  := 0;
        pdepth := 0;
        bdepth := 0;
        start  := j;
        while j < toks.count {
            tt := toks[j].type;
            if tt == cast(Token_Type) #char "(" { pdepth += 1; }
            else if tt == cast(Token_Type) #char ")" {
                if pdepth == 0 { break; }
                pdepth -= 1;
            }
            else if tt == cast(Token_Type) #char "[" { bdepth += 1; }
            else if tt == cast(Token_Type) #char "]" { bdepth -= 1; }
            else if tt == cast(Token_Type) #char "{" && pdepth == 0 && bdepth == 0 { break; }
            else if tt == cast(Token_Type) #char "," && pdepth == 0 && bdepth == 0 {
                if group == ordinal { break; }
                group += 1;
                start = j + 1;
            }
            j += 1;
        }
        if group != ordinal { continue; }
        gs := start;
        if gs + 1 < toks.count && toks[gs].type == .IDENT && toks[gs+1].type == cast(Token_Type) #char ":" { gs += 2; }
        result := parse_type_tokens(toks, gs);
        if result.ok { return result; }
    }
    return fail;
}

struct_field_type :: (struct_name: string, field: string, depth: s64) -> Type_Ref {
    fail: Type_Ref;
    for decl: find_decls(struct_name) {
        if decl.kind != .STRUCT { continue; }
        stext, ok := get_text(decl.path);
        if !ok { continue; }
        toks := collect_tokens(stext);
        i    := 0;
        while i < toks.count {
            t := toks[i];
            if t.type != .IDENT || t.name != struct_name || t.l0 - 1 != decl.line {
                i += 1;
                continue;
            }
            j := i + 1;
            while j < toks.count && toks[j].type != cast(Token_Type) #char "{" && toks[j].type != cast(Token_Type) #char ";" { j += 1; }
            if j >= toks.count || toks[j].type != cast(Token_Type) #char "{" { break; }
            d := 1;
            j += 1;
            while j < toks.count && d > 0 {
                tt := toks[j].type;
                if tt == cast(Token_Type) #char "{" || tt == .BEGIN_STRUCT_LITERAL { d += 1; j += 1; continue; }
                if tt == cast(Token_Type) #char "}" { d -= 1; j += 1; continue; }
                if d == 1 && tt == .IDENT && toks[j].name == field && toks[j-1].type != cast(Token_Type) #char "." {
                    m := j;
                    while m + 2 < toks.count && toks[m+1].type == cast(Token_Type) #char "," && toks[m+2].type == .IDENT { m += 2; }
                    if m + 1 < toks.count && toks[m+1].type == cast(Token_Type) #char ":" {
                        n := m + 2;
                        if n < toks.count && toks[n].type != cast(Token_Type) #char "=" && toks[n].type != cast(Token_Type) #char ":" {
                            result := parse_type_tokens(toks, n);
                            if result.ok { return result; }
                        }
                    }
                }
                j += 1;
            }
            break;
        }
    }
    return fail;
}

parse_type_tokens :: (toks: []Tok, start: s64) -> Type_Ref {
    fail: Type_Ref;
    i  := start;
    ad := 0;
    while i < toks.count {
        tt := toks[i].type;
        if tt == cast(Token_Type) #char "*" { i += 1; continue; }
        if tt == cast(Token_Type) #char "[" {
            d := 1;
            i += 1;
            while i < toks.count && d > 0 {
                if toks[i].type == cast(Token_Type) #char "[" { d += 1; }
                if toks[i].type == cast(Token_Type) #char "]" { d -= 1; }
                i += 1;
            }
            ad += 1;
            continue;
        }
        if tt == .IDENT {
            name := toks[i].name;
            while i + 2 < toks.count && toks[i+1].type == cast(Token_Type) #char "." && toks[i+2].type == .IDENT {
                i += 2;
                name = toks[i].name;
            }
            result: Type_Ref;
            result.name        = name;
            result.array_depth = ad;
            result.ok          = true;
            return result;
        }
        return fail;
    }
    return fail;
}
