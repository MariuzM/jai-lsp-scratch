Const_Line :: struct {
    ok:   bool;
    name: string;
    rest: string;
}

Align_Rule :: struct {
    parse:        (Out_Line) -> Const_Line;
    sep:          string;
    sep_attached: bool;
}

align_groups :: (lines: []Out_Line, rule: Align_Rule) {
    i := 0;
    while i < lines.count {
        first := rule.parse(lines[i]);
        if !first.ok { i += 1; continue; }
        indent := lines[i].indent;
        j      := i + 1;
        while j < lines.count {
            next := rule.parse(lines[j]);
            if !next.ok || lines[j].indent != indent { break; }
            j += 1;
        }
        if j - i >= 2 {
            max_name := 0;
            for k: i..j-1 {
                p := rule.parse(lines[k]);
                if p.name.count > max_name { max_name = p.name.count; }
            }
            for k: i..j-1 {
                p := rule.parse(lines[k]);
                builder: String_Builder;
                for 1..indent { append(*builder, "    "); }
                append(*builder, p.name);
                if rule.sep_attached { append(*builder, rule.sep); }
                for 1..(max_name - p.name.count + 1) { append(*builder, " "); }
                if !rule.sep_attached { append(*builder, rule.sep); }
                append(*builder, p.rest);
                lines[k].text = builder_to_string(*builder);
            }
        }
        i = j;
    }
}

parse_const_line :: (line: Out_Line) -> Const_Line {
    result: Const_Line;
    if line.protected { return result; }
    t := line.text;
    k := line.indent * 4;
    if t.count <= k { return result; }

    start := k;
    while k < t.count && is_word_char(t[k]) { k += 1; }
    if k == start { return result; }
    if t[start] >= #char "0" && t[start] <= #char "9" { return result; }
    name := slice(t, start, k - start);

    while k < t.count && t[k] == #char " " { k += 1; }
    if k + 2 >= t.count || t[k] != #char ":" || t[k+1] != #char ":" { return result; }
    k += 2;
    if t[k] != #char " " && t[k] != #char "(" { return result; }
    while k < t.count && t[k] == #char " " { k += 1; }
    rest := slice(t, k, t.count - k);
    if rest.count == 0 { return result; }

    if rest[0] == #char "(" {
        found_foreign, _ := contains(rest, "#foreign");
        if !found_foreign { return result; }
    }
    if starts_with(rest, "#string") { return result; }
    if starts_with(rest, "struct") || starts_with(rest, "enum") || starts_with(rest, "union") || starts_with(rest, "inline") { return result; }
    found_semicolon, _ := contains(rest, #char ";");
    if !found_semicolon { return result; }

    result.ok   = true;
    result.name = name;
    result.rest = rest;
    return result;
}

jump_keyword_at :: (t: string, m: s64) -> bool {
    if m > 0 && is_word_char(t[m-1]) { return false; }
    KEYWORDS :: string.["return", "break", "continue"];
    for kw: KEYWORDS {
        if m + kw.count <= t.count && slice(t, m, kw.count) == kw
        && (m + kw.count == t.count || !is_word_char(t[m + kw.count])) {
            return true;
        }
    }
    return false;
}

parse_if_return_line :: (line: Out_Line) -> Const_Line {
    result: Const_Line;
    if line.protected { return result; }
    t := line.text;
    k := line.indent * 4;
    if t.count <= k + 3 { return result; }
    if slice(t, k, 3) != "if " { return result; }
    if has_then_keyword(slice(t, k, t.count - k)) { return result; }

    m     := k + 3;
    depth := 0;
    pos   := -1;
    while m < t.count {
        c := t[m];
        if c == #char "\"" {
            m = skip_string(t, m);
            continue;
        }
        if c == #char "/" && m + 1 < t.count && t[m+1] == #char "/" { break; }
        if c == #char "(" || c == #char "[" || c == #char "{" { depth += 1; }
        if c == #char ")" || c == #char "]" || c == #char "}" { depth -= 1; }
        if depth == 0 && jump_keyword_at(t, m) {
            pos = m;
            break;
        }
        m += 1;
    }
    if pos == -1 { return result; }

    cond_end := pos;
    while cond_end > k && t[cond_end - 1] == #char " " { cond_end -= 1; }
    if cond_end <= k + 3 { return result; }
    name               := slice(t, k, cond_end - k);
    rest               := slice(t, pos, t.count - pos);
    found_semicolon, _ := contains(rest, #char ";");
    if !found_semicolon { return result; }

    result.ok   = true;
    result.name = name;
    result.rest = rest;
    return result;
}

parse_foreign_line :: (line: Out_Line) -> Const_Line {
    result: Const_Line;
    if line.protected { return result; }
    t := line.text;
    k := line.indent * 4;
    if t.count <= k { return result; }

    pos := -1;
    m   := k;
    while m < t.count {
        c := t[m];
        if c == #char "\"" {
            m = skip_string(t, m);
            continue;
        }
        if c == #char "/" && m + 1 < t.count && t[m+1] == #char "/" { break; }
        if c == #char "#" && m + 8 <= t.count && slice(t, m, 8) == "#foreign"
        && (m + 8 == t.count || !is_word_char(t[m+8])) {
            pos = m;
            break;
        }
        m += 1;
    }
    if pos == -1 { return result; }

    name_end := pos;
    while name_end > k && t[name_end - 1] == #char " " { name_end -= 1; }
    if name_end == k { return result; }
    name               := slice(t, k, name_end - k);
    rest               := slice(t, pos, t.count - pos);
    found_semicolon, _ := contains(rest, #char ";");
    if !found_semicolon { return result; }

    result.ok   = true;
    result.name = name;
    result.rest = rest;
    return result;
}

parse_field_line :: (line: Out_Line) -> Const_Line {
    result: Const_Line;
    if line.protected { return result; }
    t := line.text;
    k := line.indent * 4;
    if t.count <= k { return result; }

    start := k;
    while k < t.count && is_word_char(t[k]) { k += 1; }
    if k == start { return result; }
    if t[start] >= #char "0" && t[start] <= #char "9" { return result; }
    name := slice(t, start, k - start);

    while k < t.count && t[k] == #char " " { k += 1; }
    if k >= t.count || t[k] != #char ":" { return result; }
    k += 1;
    if k >= t.count { return result; }
    if t[k] == #char ":" || t[k] == #char "=" { return result; }
    while k < t.count && t[k] == #char " " { k += 1; }
    rest := slice(t, k, t.count - k);
    if rest.count == 0 { return result; }
    found_semicolon, _ := contains(rest, #char ";");
    if !found_semicolon { return result; }

    result.ok   = true;
    result.name = name;
    result.rest = rest;
    return result;
}

parse_assign_line :: (line: Out_Line) -> Const_Line {
    result: Const_Line;
    if line.protected { return result; }
    t := line.text;
    k := line.indent * 4;
    if t.count <= k { return result; }

    start := k;
    while k < t.count && (is_word_char(t[k]) || t[k] == #char "." || t[k] == #char "[" || t[k] == #char "]") { k += 1; }
    if k == start { return result; }
    if !((t[start] >= #char "a" && t[start] <= #char "z") || (t[start] >= #char "A" && t[start] <= #char "Z") || t[start] == #char "_") { return result; }
    name := slice(t, start, k - start);

    spaces := 0;
    while k < t.count && t[k] == #char " " {
        spaces += 1;
        k += 1;
    }
    if spaces == 0 { return result; }
    if k >= t.count || t[k] != #char "=" { return result; }
    k += 1;
    if k >= t.count || t[k] == #char "=" { return result; }
    while k < t.count && t[k] == #char " " { k += 1; }
    rest := slice(t, k, t.count - k);
    if rest.count == 0 { return result; }
    found_semicolon, _ := contains(rest, #char ";");
    if !found_semicolon { return result; }

    result.ok   = true;
    result.name = name;
    result.rest = rest;
    return result;
}

parse_decl_line :: (line: Out_Line) -> Const_Line {
    result: Const_Line;
    if line.protected { return result; }
    t := line.text;
    k := line.indent * 4;
    if t.count <= k { return result; }

    start := k;
    while k < t.count && is_word_char(t[k]) { k += 1; }
    if k == start { return result; }
    if t[start] >= #char "0" && t[start] <= #char "9" { return result; }
    name_end := k;

    while k < t.count {
        m := k;
        while m < t.count && t[m] == #char " " { m += 1; }
        if m >= t.count || t[m] != #char "," { break; }
        m += 1;
        while m < t.count && t[m] == #char " " { m += 1; }
        ident_start := m;
        while m < t.count && is_word_char(t[m]) { m += 1; }
        if m == ident_start { return result; }
        k        = m;
        name_end = m;
    }
    name := slice(t, start, name_end - start);

    while k < t.count && t[k] == #char " " { k += 1; }
    if k + 1 >= t.count || t[k] != #char ":" || t[k+1] != #char "=" { return result; }
    k += 2;
    while k < t.count && t[k] == #char " " { k += 1; }
    rest := slice(t, k, t.count - k);
    if rest.count == 0 { return result; }
    found_semicolon, _ := contains(rest, #char ";");
    if !found_semicolon { return result; }

    result.ok   = true;
    result.name = name;
    result.rest = rest;
    return result;
}

parse_case_line :: (line: Out_Line) -> Const_Line {
    result: Const_Line;
    if line.protected { return result; }
    t := line.text;
    k := line.indent * 4;
    if t.count <= k + 4 { return result; }
    if slice(t, k, 4) != "case" { return result; }
    after := t[k + 4];
    if after != #char " " && after != #char ";" { return result; }

    semi := -1;
    m    := k;
    while m < t.count {
        if t[m] == #char "\"" { m = skip_string(t, m); continue; }
        if t[m] == #char ";" { semi = m; break; }
        m += 1;
    }
    if semi == -1 { return result; }

    prefix := slice(t, k, semi - k + 1);
    m = semi + 1;
    spaces := 0;
    while m < t.count && t[m] == #char " " {
        spaces += 1;
        m += 1;
    }
    if spaces == 0 { return result; }
    body := slice(t, m, t.count - m);
    if body.count == 0 { return result; }
    if starts_with(body, "//") { return result; }

    result.ok   = true;
    result.name = prefix;
    result.rest = body;
    return result;
}

Chain_Kind :: enum {
    NONE;
    IF;
    ELSE_IF;
    ELSE;
}

Chain_Line :: struct {
    kind:   Chain_Kind;
    prefix: string;
    stmt:   string;
}

parse_chain_line :: (line: Out_Line) -> Chain_Line {
    result: Chain_Line;
    if line.protected { return result; }
    t := line.text;
    k := line.indent * 4;

    kind := Chain_Kind.NONE;
    if t.count > k + 5 && slice(t, k, 5) == "else " {
        k += 5;
        while k < t.count && t[k] == #char " " { k += 1; }
        if t.count > k + 3 && slice(t, k, 3) == "if " {
            kind = .ELSE_IF;
            k += 3;
        } else {
            kind = .ELSE;
        }
    } else if t.count > k + 3 && slice(t, k, 3) == "if " {
        kind = .IF;
        k += 3;
    }
    if kind == .NONE { return result; }
    if has_then_keyword(slice(t, line.indent * 4, t.count - line.indent * 4)) { return result; }

    stmt: string;
    cond: string;
    if kind == .ELSE {
        stmt = slice(t, k, t.count - k);
    } else {
        while k < t.count && t[k] == #char " " { k += 1; }
        cond_start := k;
        sep_start  := condition_boundary(t, *k);
        if sep_start == -1 || sep_start == cond_start { return result; }
        cond = trim(slice(t, cond_start, sep_start - cond_start));
        if cond.count == 0 { return result; }
        m := sep_start;
        while m < t.count && t[m] == #char " " { m += 1; }
        stmt = slice(t, m, t.count - m);
    }

    if stmt.count == 0 { return result; }
    if stmt[0] == #char "{" {
        close := find_matching_close(stmt);
        if close == -1 { return result; }
        after := trim(slice(stmt, close + 1, stmt.count - close - 1));
        if after.count > 0 && !starts_with(after, "//") { return result; }
    } else {
        if ambiguous_spacing(stmt) { return result; }
    }
    if starts_with(stmt, "//") { return result; }
    found_semicolon, _ := contains(stmt, #char ";");
    if !found_semicolon { return result; }

    result.kind = kind;
    result.stmt = stmt;
    if kind == {
        case .IF;      result.prefix = tprint("if %", cond);
        case .ELSE_IF; result.prefix = tprint("else if %", cond);
        case .ELSE;    result.prefix = "else";
    }
    return result;
}

align_if_else_chains :: (lines: []Out_Line) {
    i := 0;
    while i < lines.count {
        first := parse_chain_line(lines[i]);
        if first.kind != .IF { i += 1; continue; }
        indent := lines[i].indent;

        j := i + 1;
        while j < lines.count && lines[j].indent == indent {
            next := parse_chain_line(lines[j]);
            if next.kind != .ELSE_IF && next.kind != .ELSE { break; }
            j += 1;
            if next.kind == .ELSE { break; }
        }

        max_prefix := 0;
        for k: i..j-1 {
            p := parse_chain_line(lines[k]);
            if p.prefix.count > max_prefix { max_prefix = p.prefix.count; }
        }
        for k: i..j-1 {
            p := parse_chain_line(lines[k]);
            builder: String_Builder;
            for 1..indent { append(*builder, "    "); }
            append(*builder, p.prefix);
            for 1..(max_prefix - p.prefix.count + 1) { append(*builder, " "); }
            append(*builder, brace_statement(p.stmt));
            lines[k].text = builder_to_string(*builder);
        }
        i = j;
    }
}

strip_then_before_jump :: (lines: []Out_Line) {
    for * lines {
        if it.protected || it.text.count == 0 { continue; }
        t := it.text;
        k := it.indent * 4;
        if t.count <= k + 3 { continue; }
        if slice(t, k, 3) != "if " && (t.count <= k + 5 || slice(t, k, 5) != "else ") { continue; }

        m     := k;
        depth := 0;
        while m < t.count {
            c := t[m];
            if c == #char "\"" {
                m = skip_string(t, m);
                continue;
            }
            if c == #char "/" && m + 1 < t.count && t[m+1] == #char "/" { break; }
            if c == #char "(" || c == #char "[" || c == #char "{" { depth += 1; }
            if c == #char ")" || c == #char "]" || c == #char "}" { depth -= 1; }
            if depth == 0 && c == #char "t" && m > k && t[m-1] == #char " "
            && m + 4 < t.count && slice(t, m, 4) == "then" && t[m+4] == #char " " {
                n := m + 4;
                while n < t.count && t[n] == #char " " { n += 1; }
                if jump_keyword_at(t, n) {
                    builder: String_Builder;
                    append(*builder, slice(t, 0, m));
                    append(*builder, slice(t, n, t.count - n));
                    it.text = builder_to_string(*builder);
                }
                break;
            }
            m += 1;
        }
    }
}

wrap_inline_controls :: (lines: []Out_Line) {
    for * lines {
        if it.protected { continue; }
        body:   string;
        prefix: string;
        chain := parse_chain_line(it);
        if chain.kind != .NONE {
            if chain.stmt[0] == #char "{" { continue; }
            if jump_keyword_at(chain.stmt, 0) { continue; }
            if chain.kind == .ELSE { body = chain.stmt; }
            else { body = tprint("then %", chain.stmt); }
            prefix = chain.prefix;
        } else {
            loop := parse_loop_line(it);
            if !loop.ok || loop.rest[0] == #char "{" { continue; }
            prefix = loop.name;
            body   = brace_statement(loop.rest);
        }
        builder: String_Builder;
        for 1..it.indent { append(*builder, "    "); }
        append(*builder, prefix);
        append(*builder, " ");
        append(*builder, body);
        it.text = builder_to_string(*builder);
    }
}

#scope_file

parse_loop_line :: (line: Out_Line) -> Const_Line {
    result: Const_Line;
    t := line.text;
    k := line.indent * 4;
    if t.count <= k + 6 { return result; }
    if slice(t, k, 6) != "while " && slice(t, k, 4) != "for " { return result; }

    head_start := k;
    sep_start  := condition_boundary(t, *k);
    if sep_start == -1 { return result; }

    m := sep_start;
    while m < t.count && t[m] == #char " " { m += 1; }
    stmt := slice(t, m, t.count - m);
    if stmt.count == 0 || starts_with(stmt, "//") { return result; }
    if ambiguous_spacing(stmt) { return result; }
    found_semicolon, _ := contains(stmt, #char ";");
    if !found_semicolon { return result; }

    result.ok   = true;
    result.name = slice(t, head_start, sep_start - head_start);
    result.rest = stmt;
    return result;
}

condition_boundary :: (t: string, k: *s64) -> s64 {
    paren := 0;
    while k.* < t.count {
        c := t[k.*];
        if c == #char "\"" {
            k.* = skip_string(t, k.*);
            continue;
        }
        if c == #char "(" || c == #char "[" { paren += 1; }
        if c == #char ")" || c == #char "]" { paren -= 1; }
        if c == #char "{" && paren == 0 { return k.*; }
        if c == #char " " && paren == 0 && k.* + 1 < t.count && t[k.* + 1] == #char " " {
            return k.*;
        }
        k.* += 1;
    }
    return -1;
}

ambiguous_spacing :: (stmt: string) -> bool {
    k := 0;
    while k < stmt.count {
        c := stmt[k];
        if c == #char "\"" {
            k = skip_string(stmt, k);
            continue;
        }
        if c == #char " " && k + 1 < stmt.count && stmt[k+1] == #char " " {
            m := k;
            while m < stmt.count && stmt[m] == #char " " { m += 1; }
            if m + 1 < stmt.count && stmt[m] == #char "/" && stmt[m+1] == #char "/" { return false; }
            return true;
        }
        k += 1;
    }
    return false;
}

brace_statement :: (stmt: string) -> string {
    if stmt[0] == #char "{" { return normalize_inline_block(stmt); }
    semi := -1;
    k    := 0;
    while k < stmt.count {
        c := stmt[k];
        if c == #char "\"" {
            k = skip_string(stmt, k);
            continue;
        }
        if c == #char "/" && k + 1 < stmt.count && stmt[k+1] == #char "/" { break; }
        if c == #char ";" { semi = k; }
        k += 1;
    }
    if semi == -1 { return stmt; }
    core := slice(stmt, 0, semi + 1);
    tail := trim(slice(stmt, semi + 1, stmt.count - semi - 1));
    if tail.count > 0 { return tprint("{ % }  %", core, tail); }
    return tprint("{ % }", core);
}

find_matching_close :: (stmt: string) -> s64 {
    depth := 0;
    k     := 0;
    while k < stmt.count {
        c := stmt[k];
        if c == #char "\"" {
            k = skip_string(stmt, k);
            continue;
        }
        if c == #char "{" { depth += 1; }
        if c == #char "}" {
            depth -= 1;
            if depth == 0 { return k; }
        }
        k += 1;
    }
    return -1;
}

normalize_inline_block :: (stmt: string) -> string {
    close := find_matching_close(stmt);
    if close == -1 { return stmt; }

    inner := slice(stmt, 1, close - 1);
    tail  := trim(slice(stmt, close + 1, stmt.count - close - 1));

    builder: String_Builder;
    append(*builder, "{");
    piece_start := 0;
    depth       := 0;
    k           := 0;
    while k < inner.count {
        c := inner[k];
        if c == #char "\"" {
            k = skip_string(inner, k);
            continue;
        }
        if c == #char "{" { depth += 1; }
        if c == #char "}" { depth -= 1; }
        if c == #char ";" && depth == 0 {
            piece := trim(slice(inner, piece_start, k - piece_start + 1));
            if piece.count > 0 { append(*builder, " "); append(*builder, piece); }
            piece_start = k + 1;
        }
        k += 1;
    }
    rest := trim(slice(inner, piece_start, inner.count - piece_start));
    if rest.count > 0 { append(*builder, " "); append(*builder, rest); }
    append(*builder, " }");
    if tail.count > 0 { append(*builder, "  "); append(*builder, tail); }
    return builder_to_string(*builder);
}
