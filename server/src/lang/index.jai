Decl_Kind :: enum {
    PROCEDURE;
    STRUCT;
    ENUM;
    ENUM_MEMBER;
    CONSTANT;
    VARIABLE;
}

Decl :: struct {
    name:      string;
    path:      string;
    line:      s32;
    col:       s32;
    name_end:  s32;
    kind:      Decl_Kind;
    signature: string;
}

g_decls: [..] Decl;

index_file :: (path: string, content: string) {
    remove_decls_for_file(path);

    toks := collect_tokens(content);

    curly_stack:[..] bool;
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
                    add_decl(path, content, t, kind);
                    if kind == .ENUM { index_enum_members(path, toks, i + 3, t.name); }
                } else {
                    add_decl(path, content, t, .VARIABLE);
                }
            }
        }
        i += 1;
    }
}

remove_decls_for_file :: (path: string) {
    push_allocator(g_heap);
    for g_decls {
        if it.path == path { free(it.name); free(it.path); free(it.signature); remove it; }
    }
}

find_decls :: (name: string) -> [..] Decl {
    results: [..] Decl;
    for g_decls if it.name == name array_add(*results, it);
    return results;
}

decls_in_file :: (path: string) -> [..] Decl {
    results: [..] Decl;
    for g_decls if it.path == path array_add(*results, it);
    return results;
}

Local_Hit :: struct {
    line:     s32;
    col:      s32;
    name_end: s32;
}

find_local_decl_sites :: (content: string, name: string) -> [..] Local_Hit {
    hits: [..] Local_Hit;
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

semantic_spans :: (content: string) -> [..] Ident_Span {
    spans: [..] Ident_Span;

    kinds: Table(string, s32);
    init(*kinds, 8192);
    for g_decls {
        index := semantic_kind_index(it.kind);
        if index == -1 { continue; }
        existing, found := table_find(*kinds, it.name);
        if found && existing <= index { continue; }
        table_set(*kinds, it.name, index);
    }

    toks := collect_tokens(content);
    for toks {
        if it.type != .IDENT { continue; }
        index, found := table_find(*kinds, it.name);
        if !found { continue; }
        span: Ident_Span;
        span.line       = it.l0 - 1;
        span.col        = it.c0 - 1;
        span.length     = cast(s32) it.name.count;
        span.token_kind = index;
        array_add(*spans, span);
    }
    return spans;
}

#scope_file

semantic_kind_index :: (kind: Decl_Kind) -> s32 {
    if kind == {
        case .ENUM;        return 0;
        case .STRUCT;      return 1;
        case .ENUM_MEMBER; return 2;
        case .PROCEDURE;   return 3;
    }
    return -1;
}

index_enum_members :: (path: string, toks: [] Tok, enum_keyword_index: s64, enum_name: string) {
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
            push_allocator(g_heap);
            decl: Decl;
            decl.name      = copy_string(t.name);
            decl.path      = copy_string(path);
            decl.line      = t.l0 - 1;
            decl.col       = t.c0 - 1;
            decl.name_end  = t.c0 - 1 + cast(s32) t.name.count;
            decl.kind      = .ENUM_MEMBER;
            decl.signature = sprint("%.%", enum_name, t.name);
            array_add(*g_decls, decl);
        }
        prev = t.type;
        j += 1;
    }
}

Tok :: struct {
    type: Token_Type;
    l0, c0, c1: s32;
    name: string;
}

collect_tokens :: (content: string) -> [..] Tok {
    toks:  [..] Tok;
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

add_decl :: (path: string, content: string, t: Tok, kind: Decl_Kind) {
    line0 := t.l0 - 1;
    sig   := trim(get_line(content, line0));

    push_allocator(g_heap);
    decl: Decl;
    decl.name      = copy_string(t.name);
    decl.path      = copy_string(path);
    decl.line      = cast(s32) line0;
    decl.col       = t.c0 - 1;
    decl.name_end  = t.c0 - 1 + cast(s32) t.name.count;
    decl.kind      = kind;
    decl.signature = copy_string(sig);
    array_add(*g_decls, decl);
}
