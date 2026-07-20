Decl_Kind :: enum {
    PROCEDURE;
    STRUCT;
    ENUM;
    ENUM_MEMBER;
    CONSTANT;
    VARIABLE;
}

Decl :: struct {
    name:            string;
    path:            string;
    line:            s32;
    col:             s32;
    name_end:        s32;
    kind:            Decl_Kind;
    signature:       string;
    module:          string;
    completion_base: string;
}

g_decls:            [..]Decl;
g_decls_generation: s64;

index_file :: (path: string, content: string, module := "") {
    remove_decls_for_file(path);

    toks := collect_tokens(content);

    curly_stack: [..]bool;
    opaque_depth            := 0;
    pending_transparent     := false;
    last_closed_transparent := false;
    paren                   := 0;
    bracket                 := 0;
    i                       := 0;

    while i < toks.count {
        t := toks[i];
        if t.type == {
            case .KEYWORD_IF;
                if i + 1 < toks.count && toks[i+1].type == cast(Token_Type) #char "#" { pending_transparent = true; }
            case .KEYWORD_ELSE;
                if last_closed_transparent { pending_transparent = true; }
            case cast(Token_Type) #char ";";
                pending_transparent = false;
            case cast(Token_Type) #char "{";
                array_add(*curly_stack, pending_transparent);
                if !pending_transparent { opaque_depth += 1; }
                pending_transparent = false;
            case .BEGIN_STRUCT_LITERAL;
                array_add(*curly_stack, false);
                opaque_depth += 1;
            case cast(Token_Type) #char "}";
                if curly_stack.count > 0 {
                    last_closed_transparent = curly_stack[curly_stack.count - 1];
                    if !last_closed_transparent { opaque_depth -= 1; }
                    curly_stack.count -= 1;
                }
            case cast(Token_Type) #char "("; paren += 1;
            case cast(Token_Type) #char ")"; paren -= 1;
            case cast(Token_Type) #char "["; bracket += 1;
            case .BEGIN_ARRAY_LITERAL;       bracket += 1;
            case cast(Token_Type) #char "]"; bracket -= 1;
        }

        if opaque_depth == 0 && paren == 0 && bracket == 0 && t.type == .IDENT && i + 1 < toks.count
        && toks[i+1].type == cast(Token_Type) #char ":" {
            prev_is_dot := i > 0 && toks[i-1].type == cast(Token_Type) #char ".";
            if !prev_is_dot {
                if i + 2 < toks.count && toks[i+2].type == cast(Token_Type) #char ":" {
                    kind := Decl_Kind.CONSTANT;
                    if i + 3 < toks.count {
                        n := toks[i+3].type;
                        if n == .KEYWORD_STRUCT || n == .KEYWORD_UNION          { kind = .STRUCT; }
                        else if n == .KEYWORD_ENUM || n == .KEYWORD_ENUM_FLAGS  { kind = .ENUM; }
                        else if n == cast(Token_Type) #char "("                 { kind = .PROCEDURE; }
                        else if n == .KEYWORD_INLINE || n == .KEYWORD_NO_INLINE { kind = .PROCEDURE; }
                    }
                    add_decl(path, content, t, kind, module);
                    if kind == .ENUM { index_enum_members(path, toks, i + 3, t.name, module); }
                } else {
                    add_decl(path, content, t, .VARIABLE, module);
                }
            }
        }
        i += 1;
    }
}

remove_decls_for_file :: (path: string) {
    push_allocator(g_heap);
    for g_decls {
        if it.path == path {
            free(it.name);
            free(it.path);
            free(it.signature);
            free(it.module);
            free(it.completion_base);
            remove it;
        }
    }
    g_decls_generation += 1;
}

find_decls :: (name: string) -> [..]Decl {
    results: [..]Decl;
    for g_decls if it.name == name array_add(*results, it);
    return results;
}

decls_in_file :: (path: string) -> [..]Decl {
    results: [..]Decl;
    for g_decls if it.path == path array_add(*results, it);
    return results;
}

Local_Hit :: struct {
    line:     s32;
    col:      s32;
    name_end: s32;
}

in_type_position :: (toks: []Tok, i: s64) -> bool {
    p := i - 1;
    while p >= 0 {
        pt := toks[p].type;
        is_type_prefix := pt == cast(Token_Type) #char "*"
                       || pt == cast(Token_Type) #char "["
                       || pt == cast(Token_Type) #char "]"
                       || pt == .BEGIN_ARRAY_LITERAL
                       || pt == .DOUBLE_DOT;
        if !is_type_prefix { break; }
        p -= 1;
    }
    return p >= 0 && toks[p].type == cast(Token_Type) #char ":";
}

find_local_decl_sites :: (content: string, name: string) -> [..]Local_Hit {
    hits: [..]Local_Hit;
    toks := collect_tokens(content);
    if toks.count == 0 { return hits; }
    for i: 0..toks.count-1 {
        t := toks[i];
        if t.type != .IDENT || t.name != name { continue; }
        if i + 1 >= toks.count || toks[i+1].type != cast(Token_Type) #char ":" { continue; }
        if i > 0 && toks[i-1].type == cast(Token_Type) #char "." { continue; }
        hit: Local_Hit;
        hit.line     = t.l0 - 1;
        hit.col      = t.c0 - 1;
        hit.name_end = t.c0 - 1 + cast(s32) name.count;
        array_add(*hits, hit);
    }
    return hits;
}

find_scoped_local :: (content: string, name: string, line: s32, col: s32) -> bool, Local_Hit {
    result: Local_Hit;
    toks := collect_tokens(content);

    Scope_Entry :: struct {
        depth: s64;
        hit:   Local_Hit;
    }
    stack: [..]Scope_Entry;

    curly := 0;
    paren := 0;
    for i: 0..toks.count-1 {
        t      := toks[i];
        t_line := t.l0 - 1;
        t_col  := t.c0 - 1;
        if t_line > line || (t_line == line && t_col > col) { break; }

        if t.type == {
            case cast(Token_Type) #char "{"; curly += 1;
            case .BEGIN_STRUCT_LITERAL;      curly += 1;
            case cast(Token_Type) #char "}";
                curly -= 1;
                if curly < 0 { curly = 0; }
                while stack.count > 0 && stack[stack.count - 1].depth > curly { stack.count -= 1; }
            case cast(Token_Type) #char "("; paren += 1;
            case cast(Token_Type) #char ")";
                paren -= 1;
                if paren < 0 { paren = 0; }
        }
        if t.type != .IDENT || t.name != name { continue; }
        if i > 0 && toks[i-1].type == cast(Token_Type) #char "." { continue; }
        if in_type_position(toks, i) { continue; }

        j := i;
        while j + 2 < toks.count && toks[j+1].type == cast(Token_Type) #char "," && toks[j+2].type == .IDENT { j += 2; }
        is_decl := j + 1 < toks.count && toks[j+1].type == cast(Token_Type) #char ":" && !(j + 2 < toks.count && toks[j+2].type == cast(Token_Type) #char ":");
        if !is_decl { continue; }

        depth := curly;
        if paren > 0 { depth = curly + 1; }
        p := i - 1;
        if p >= 0 && toks[p].type == cast(Token_Type) #char "*" { p -= 1; }
        if p >= 0 && toks[p].type == .KEYWORD_FOR { depth = curly + 1; }

        entry: Scope_Entry;
        entry.depth        = depth;
        entry.hit.line     = t_line;
        entry.hit.col      = t_col;
        entry.hit.name_end = t_col + cast(s32) name.count;
        array_add(*stack, entry);
    }
    if stack.count == 0 { return false, result; }
    return true, stack[stack.count - 1].hit;
}

get_line :: (content: string, line0: s64) -> string {
    start   := 0;
    current := 0;
    for i: 0..content.count-1 {
        if current == line0 {
            start = i;
            end := i;
            while end < content.count && content[end] != #char "\n" { end += 1; }
            return slice(content, start, end - start);
        }
        if content[i] == #char "\n" { current += 1; }
    }
    return "";
}

Ident_Span :: struct {
    line:       s32;
    col:        s32;
    length:     s32;
    token_kind: s32;
}

semantic_spans :: (content: string, path: string) -> [..]Ident_Span {
    spans: [..]Ident_Span;
    kinds := semantic_kinds();

    file_kinds: Table(string, s32);
    for g_decls {
        if it.path != path { continue; }
        index           := semantic_kind_index(it.kind);
        existing, found := table_find(*file_kinds, it.name);
        if found && existing <= index { continue; }
        table_set(*file_kinds, it.name, index);
    }

    Local_Entry :: struct {
        name:  string;
        depth: s64;
    }
    local_stack:  [..]Local_Entry;
    local_counts: Table(string, s32);

    toks  := collect_tokens(content);
    curly := 0;
    paren := 0;
    for i: 0..toks.count-1 {
        t := toks[i];
        if t.type == {
            case cast(Token_Type) #char "{"; curly += 1;
            case .BEGIN_STRUCT_LITERAL;      curly += 1;
            case cast(Token_Type) #char "}";
                curly -= 1;
                if curly < 0 { curly = 0; }
                while local_stack.count > 0 && local_stack[local_stack.count - 1].depth > curly {
                    entry := local_stack[local_stack.count - 1];
                    local_stack.count -= 1;
                    count, found := table_find(*local_counts, entry.name);
                    if found {
                        if count <= 1 { table_remove(*local_counts, entry.name); }
                        else          { table_set(*local_counts, entry.name, count - 1); }
                    }
                }
            case cast(Token_Type) #char "("; paren += 1;
            case cast(Token_Type) #char ")";
                paren -= 1;
                if paren < 0 { paren = 0; }
        }
        if t.type != .IDENT { continue; }

        prev_is_dot := i > 0 && toks[i-1].type == cast(Token_Type) #char ".";
        if !prev_is_dot && !in_type_position(toks, i) {
            j := i;
            while j + 2 < toks.count && toks[j+1].type == cast(Token_Type) #char "," && toks[j+2].type == .IDENT { j += 2; }
            is_decl := j + 1 < toks.count && toks[j+1].type == cast(Token_Type) #char ":"
            && !(j + 2 < toks.count && toks[j+2].type == cast(Token_Type) #char ":");
            if is_decl {
                depth := curly;
                if paren > 0 { depth = curly + 1; }
                p := i - 1;
                if p >= 0 && toks[p].type == cast(Token_Type) #char "*" { p -= 1; }
                if p >= 0 && toks[p].type == .KEYWORD_FOR { depth = curly + 1; }
                count, found := table_find(*local_counts, t.name);
                if found { table_set(*local_counts, t.name, count + 1); }
                else     { table_set(*local_counts, t.name, 1); }
                entry: Local_Entry;
                entry.name  = t.name;
                entry.depth = depth;
                array_add(*local_stack, entry);
            }
        }

        _, is_local := table_find(*local_counts, t.name);
        if is_local { continue; }

        index, found := table_find(*file_kinds, t.name);
        if !found { index, found = table_find(kinds, t.name); }
        if !found || index == -1 { continue; }

        span: Ident_Span;
        span.line       = t.l0 - 1;
        span.col        = t.c0 - 1;
        span.length     = cast(s32) t.name.count;
        span.token_kind = index;
        array_add(*spans, span);
    }
    return spans;
}

#scope_file

g_kinds_cache:            Table(string, s32);
g_kinds_cache_generation: s64 = -1;

semantic_kinds :: () -> *Table(string, s32) {
    if g_kinds_cache_generation != g_decls_generation {
        push_allocator(g_heap);
        table_reset(*g_kinds_cache);
        for g_decls {
            index := semantic_kind_index(it.kind);
            if index == -1 { continue; }
            existing, found := table_find(*g_kinds_cache, it.name);
            if found && existing <= index { continue; }
            table_set(*g_kinds_cache, it.name, index);
        }
        g_kinds_cache_generation = g_decls_generation;
    }
    return *g_kinds_cache;
}

semantic_kind_index :: (kind: Decl_Kind) -> s32 {
    if kind == {
        case .ENUM;        return 0;
        case .STRUCT;      return 1;
        case .ENUM_MEMBER; return 2;
        case .PROCEDURE;   return 3;
    }
    return -1;
}

index_enum_members :: (path: string, toks: []Tok, enum_keyword_index: s64, enum_name: string, module: string) {
    j := enum_keyword_index;
    while j < toks.count {
        t := toks[j].type;
        if t == cast(Token_Type) #char "{" { break; }
        if t == cast(Token_Type) #char ";" { return; }
        j += 1;
    }
    if j >= toks.count { return; }

    depth := 1;
    prev  := cast(Token_Type) #char "{";
    j += 1;
    while j < toks.count && depth > 0 {
        t := toks[j];
        if t.type == {
            case cast(Token_Type) #char "{"; depth += 1;
            case .BEGIN_STRUCT_LITERAL;      depth += 1;
            case cast(Token_Type) #char "}"; depth -= 1;
        }
        if depth == 1 && t.type == .IDENT
        && (prev == cast(Token_Type) #char "{" || prev == cast(Token_Type) #char ";") {
            sig  := tprint("%.%", enum_name, t.name);
            base := completion_base_json(t.name, .ENUM_MEMBER, sig, module);
            push_allocator(g_heap);
            decl: Decl;
            decl.name            = copy_string(t.name);
            decl.path            = copy_string(path);
            decl.line            = t.l0 - 1;
            decl.col             = t.c0 - 1;
            decl.name_end        = t.c0 - 1 + cast(s32) t.name.count;
            decl.kind            = .ENUM_MEMBER;
            decl.signature       = copy_string(sig);
            decl.module          = copy_string(module);
            decl.completion_base = copy_string(base);
            array_add(*g_decls, decl);
            g_decls_generation += 1;
        }
        prev = t.type;
        j += 1;
    }
}

#scope_export

Tok :: struct {
    type: Token_Type;
    l0, c0, c1: s32;
    name: string;
}

collect_tokens :: (content: string) -> [..]Tok {
    toks:  [..]Tok;
    lexer: Lexer;
    set_input_from_string(*lexer, content);
    while 1 {
        token := peek_next_token(*lexer);
        if token.type == .END_OF_INPUT { break; }
        tok: Tok;
        tok.type = token.type;
        tok.l0   = token.l0;
        tok.c0   = token.c0;
        tok.c1   = token.c1;
        if token.type == .IDENT { tok.name = copy_string(token.ident_value.name); }
        array_add(*toks, tok);
        eat_token(*lexer);
        if lexer.reported_error { break; }
    }
    return toks;
}

#scope_file

add_decl :: (path: string, content: string, t: Tok, kind: Decl_Kind, module: string) {
    line0 := t.l0 - 1;
    sig   := trim(get_line(content, line0));
    base  := completion_base_json(t.name, kind, sig, module);

    push_allocator(g_heap);
    decl: Decl;
    decl.name            = copy_string(t.name);
    decl.path            = copy_string(path);
    decl.line            = cast(s32) line0;
    decl.col             = t.c0 - 1;
    decl.name_end        = t.c0 - 1 + cast(s32) t.name.count;
    decl.kind            = kind;
    decl.signature       = copy_string(sig);
    decl.module          = copy_string(module);
    decl.completion_base = copy_string(base);
    array_add(*g_decls, decl);
    g_decls_generation += 1;
}

completion_base_json :: (name: string, kind: Decl_Kind, signature: string, module: string) -> string {
    detail: string;
    if module.count > 0 { detail = tprint("% \u2014 %", module, signature); }
    else                { detail = signature; }
    return tprint("\"label\":\"%\",\"kind\":%,\"detail\":\"%\"",
        json_escape(name), completion_kind_number(kind), json_escape(detail));
}

completion_kind_number :: (kind: Decl_Kind) -> s32 {
    if kind == {
        case .PROCEDURE;   return 3;
        case .STRUCT;      return 22;
        case .ENUM;        return 13;
        case .ENUM_MEMBER; return 20;
        case .CONSTANT;    return 21;
        case .VARIABLE;    return 6;
    }
    return 21;
}
