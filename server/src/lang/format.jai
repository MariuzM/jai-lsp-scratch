format_source :: (text: string) -> string {
    split := split_statements(text);
    return format_lines(split);
}

#scope_file

format_lines :: (text: string) -> string {
    lines: [..] Out_Line;

    s: Format_State;
    array_add(*s.case_stack, false);

    i          := 0;
    line_index := 0;
    while i < text.count {
        j := i;
        while j < text.count && text[j] != #char "\n" { j += 1; }
        line := slice(text, i, j - i);

        out: Out_Line;
        if s.here_terminator.count > 0 {
            out.text      = line;
            out.protected = true;
            if trim(line) == s.here_terminator { s.here_terminator = ""; }
        } else if s.block_comment_depth > 0 {
            out.text      = strip_trailing(line);
            out.protected = true;
            scan_line(*s, line, line_index);
        } else {
            content := trim(line);
            if content.count > 0 {
                level := s.curly + s.pb_indent;
                extra := 0;
                for s.case_stack if it extra += 1;
                first := content[0];
                if first == #char "}" || first == #char ")" || first == #char "]" {
                    if first == #char "}" && s.case_stack[s.case_stack.count - 1] { extra -= 1; }
                    level -= 1;
                } else if is_case_line(content) && s.case_stack[s.case_stack.count - 1] {
                    extra -= 1;
                }
                level += extra;
                if level < 0 { level = 0; }
                out.text   = make_line(level, content);
                out.indent = level;
            }
            scan_line(*s, line, line_index);
        }
        array_add(*lines, out);

        i = j + 1;
        line_index += 1;
    }

    lines = collapse_short_blocks(lines);
    wrap_inline_controls(lines);
    normalize_spaces(lines);

    align_constant_groups(lines);
    align_field_groups(lines);
    align_assignment_groups(lines);
    align_decl_groups(lines);
    align_case_groups(lines);
    align_if_else_pairs(lines);

    last := lines.count - 1;
    while last >= 0 && !lines[last].protected && lines[last].text.count == 0 { last -= 1; }

    builder: String_Builder;
    prev_blank  := false;
    emitted_any := false;
    for k: 0..last {
        it       := lines[k];
        is_blank := !it.protected && it.text.count == 0;
        if is_blank {
            if !emitted_any { continue; }
            if prev_blank { continue; }
        } else {
            emitted_any = true;
        }
        append(*builder, it.text);
        append(*builder, "\n");
        prev_blank = is_blank;
    }
    return builder_to_string(*builder);
}

#scope_file

Out_Line :: struct {
    text:      string;
    indent:    s64;
    protected: bool;
}

make_line :: (level: s64, content: string) -> string {
    builder: String_Builder;
    for 1..level { append(*builder, "    "); }
    append(*builder, content);
    return builder_to_string(*builder);
}

Const_Line :: struct {
    ok:   bool;
    name: string;
    rest: string;
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

align_constant_groups :: (lines: [] Out_Line) {
    i := 0;
    while i < lines.count {
        first := parse_const_line(lines[i]);
        if !first.ok { i += 1; continue; }
        indent := lines[i].indent;
        j      := i + 1;
        while j < lines.count {
            next := parse_const_line(lines[j]);
            if !next.ok || lines[j].indent != indent { break; }
            j += 1;
        }
        if j - i >= 2 {
            max_name := 0;
            for k: i..j-1 {
                p := parse_const_line(lines[k]);
                if p.name.count > max_name { max_name = p.name.count; }
            }
            for k: i..j-1 {
                p := parse_const_line(lines[k]);
                builder: String_Builder;
                for 1..indent { append(*builder, "    "); }
                append(*builder, p.name);
                for 1..(max_name - p.name.count + 1) { append(*builder, " "); }
                append(*builder, ":: ");
                append(*builder, p.rest);
                lines[k].text = builder_to_string(*builder);
            }
        }
        i = j;
    }
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

align_field_groups :: (lines: [] Out_Line) {
    i := 0;
    while i < lines.count {
        first := parse_field_line(lines[i]);
        if !first.ok { i += 1; continue; }
        indent := lines[i].indent;
        j      := i + 1;
        while j < lines.count {
            next := parse_field_line(lines[j]);
            if !next.ok || lines[j].indent != indent { break; }
            j += 1;
        }
        if j - i >= 2 {
            max_name := 0;
            for k: i..j-1 {
                p := parse_field_line(lines[k]);
                if p.name.count > max_name { max_name = p.name.count; }
            }
            for k: i..j-1 {
                p := parse_field_line(lines[k]);
                builder: String_Builder;
                for 1..indent { append(*builder, "    "); }
                append(*builder, p.name);
                append(*builder, ":");
                for 1..(max_name - p.name.count + 1) { append(*builder, " "); }
                append(*builder, p.rest);
                lines[k].text = builder_to_string(*builder);
            }
        }
        i = j;
    }
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

align_assignment_groups :: (lines: [] Out_Line) {
    i := 0;
    while i < lines.count {
        first := parse_assign_line(lines[i]);
        if !first.ok { i += 1; continue; }
        indent := lines[i].indent;
        j      := i + 1;
        while j < lines.count {
            next := parse_assign_line(lines[j]);
            if !next.ok || lines[j].indent != indent { break; }
            j += 1;
        }
        if j - i >= 2 {
            max_name := 0;
            for k: i..j-1 {
                p := parse_assign_line(lines[k]);
                if p.name.count > max_name { max_name = p.name.count; }
            }
            for k: i..j-1 {
                p := parse_assign_line(lines[k]);
                builder: String_Builder;
                for 1..indent { append(*builder, "    "); }
                append(*builder, p.name);
                for 1..(max_name - p.name.count + 1) { append(*builder, " "); }
                append(*builder, "= ");
                append(*builder, p.rest);
                lines[k].text = builder_to_string(*builder);
            }
        }
        i = j;
    }
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

align_decl_groups :: (lines: [] Out_Line) {
    i := 0;
    while i < lines.count {
        first := parse_decl_line(lines[i]);
        if !first.ok { i += 1; continue; }
        indent := lines[i].indent;
        j      := i + 1;
        while j < lines.count {
            next := parse_decl_line(lines[j]);
            if !next.ok || lines[j].indent != indent { break; }
            j += 1;
        }
        if j - i >= 2 {
            max_name := 0;
            for k: i..j-1 {
                p := parse_decl_line(lines[k]);
                if p.name.count > max_name { max_name = p.name.count; }
            }
            for k: i..j-1 {
                p := parse_decl_line(lines[k]);
                builder: String_Builder;
                for 1..indent { append(*builder, "    "); }
                append(*builder, p.name);
                for 1..(max_name - p.name.count + 1) { append(*builder, " "); }
                append(*builder, ":= ");
                append(*builder, p.rest);
                lines[k].text = builder_to_string(*builder);
            }
        }
        i = j;
    }
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
        if t[m] == #char "\"" {
            m += 1;
            while m < t.count {
                if t[m] == #char "\\" { m += 2; continue; }
                if t[m] == #char "\"" { m += 1; break; }
                m += 1;
            }
            continue;
        }
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

align_case_groups :: (lines: [] Out_Line) {
    i := 0;
    while i < lines.count {
        first := parse_case_line(lines[i]);
        if !first.ok { i += 1; continue; }
        indent := lines[i].indent;
        j      := i + 1;
        while j < lines.count {
            next := parse_case_line(lines[j]);
            if !next.ok || lines[j].indent != indent { break; }
            j += 1;
        }
        if j - i >= 2 {
            max_prefix := 0;
            for k: i..j-1 {
                p := parse_case_line(lines[k]);
                if p.name.count > max_prefix { max_prefix = p.name.count; }
            }
            for k: i..j-1 {
                p := parse_case_line(lines[k]);
                builder: String_Builder;
                for 1..indent { append(*builder, "    "); }
                append(*builder, p.name);
                for 1..(max_prefix - p.name.count + 1) { append(*builder, " "); }
                append(*builder, p.rest);
                lines[k].text = builder_to_string(*builder);
            }
        }
        i = j;
    }
}

split_statements :: (text: string) -> string {
    builder: String_Builder;
    block_comment_depth := 0;
    here_terminator     := "";

    i := 0;
    while i < text.count {
        j := i;
        while j < text.count && text[j] != #char "\n" { j += 1; }
        line := slice(text, i, j - i);

        if here_terminator.count > 0 {
            append(*builder, line);
            append(*builder, "\n");
            if trim(line) == here_terminator { here_terminator = ""; }
        } else {
            remaining := line;
            while 1 {
                split_at := find_split_point(remaining, *block_comment_depth, *here_terminator);
                if split_at == -1 {
                    append(*builder, strip_trailing(remaining));
                    append(*builder, "\n");
                    break;
                }
                append(*builder, strip_trailing(slice(remaining, 0, split_at)));
                append(*builder, "\n");
                rest := slice(remaining, split_at, remaining.count - split_at);
                k    := 0;
                while k < rest.count && (rest[k] == #char " " || rest[k] == #char "\t") { k += 1; }
                rest = slice(rest, k, rest.count - k);
                if rest.count == 0 { break; }
                remaining = rest;
            }
        }

        i = j + 1;
    }
    return builder_to_string(*builder);
}

find_split_point :: (s: string, block_comment_depth: *s64, here_terminator: *string) -> s64 {
    bc    := block_comment_depth.*;
    curly := 0;
    paren := 0;
    brace_positions: [64] s64;
    brace_bc:        [64] s64;
    brace_count := 0;

    content := trim(s);
    is_case := is_case_line(content);
    semis   := 0;

    k := 0;
    while k < s.count {
        if bc > 0 {
            if k + 1 < s.count && s[k] == #char "*" && s[k+1] == #char "/" {
                bc -= 1;
                k += 2;
                continue;
            }
            if k + 1 < s.count && s[k] == #char "/" && s[k+1] == #char "*" {
                bc += 1;
                k += 2;
                continue;
            }
            k += 1;
            continue;
        }

        c := s[k];

        if c == #char "/" && k + 1 < s.count {
            if s[k+1] == #char "/" { break; }
            if s[k+1] == #char "*" { bc += 1; k += 2; continue; }
        }

        if c == #char "\"" {
            k += 1;
            while k < s.count {
                if s[k] == #char "\\" { k += 2; continue; }
                if s[k] == #char "\"" { k += 1; break; }
                k += 1;
            }
            continue;
        }

        if c == #char "#" && k + 7 <= s.count && slice(s, k + 1, 6) == "string"
        && (k + 7 == s.count || !is_word_char(s[k+7])) {
            m := k + 7;
            while m < s.count && (s[m] == #char " " || s[m] == #char "\t") { m += 1; }
            start := m;
            while m < s.count && is_word_char(s[m]) { m += 1; }
            if m > start { here_terminator.* = slice(s, start, m - start); }
            block_comment_depth.* = bc;
            return -1;
        }

        if c == {
            case #char "{";
                if brace_count < 64 {
                    brace_positions[brace_count] = k;
                    brace_bc[brace_count]        = bc;
                    brace_count += 1;
                }
                curly += 1;
            case #char "}";
                if brace_count > 0 { brace_count -= 1; }
                curly -= 1;
            case #char "("; paren += 1;
            case #char ")"; paren -= 1;
            case #char "["; paren += 1;
            case #char "]"; paren -= 1;
        }

        if c == #char ";" && curly <= 0 && paren <= 0 {
            semis += 1;
            if !(is_case && semis == 1) {
                m := k + 1;
                while m < s.count && (s[m] == #char " " || s[m] == #char "\t") { m += 1; }
                if m < s.count && !(m + 1 < s.count && s[m] == #char "/" && s[m+1] == #char "/") {
                    block_comment_depth.* = bc;
                    return k + 1;
                }
            }
        }
        k += 1;
    }

    if bc == 0 && curly > 0 && brace_count > 0 {
        p := brace_positions[0];
        m := p + 1;
        while m < s.count && (s[m] == #char " " || s[m] == #char "\t") { m += 1; }
        if m < s.count && !(m + 1 < s.count && s[m] == #char "/" && s[m+1] == #char "/") {
            block_comment_depth.* = brace_bc[0];
            return p + 1;
        }
    }

    block_comment_depth.* = bc;
    return -1;
}

COLLAPSE_WIDTH :: 100;

wrap_inline_controls :: (lines: [] Out_Line) {
    for * lines {
        if it.protected { continue; }
        chain := parse_chain_line(it);
        stmt:   string;
        prefix: string;
        if chain.kind != .NONE {
            if chain.stmt[0] == #char "{" { continue; }
            prefix = chain.prefix;
            stmt   = chain.stmt;
        } else {
            loop := parse_loop_line(it);
            if !loop.ok || loop.rest[0] == #char "{" { continue; }
            prefix = loop.name;
            stmt   = loop.rest;
        }
        builder: String_Builder;
        for 1..it.indent { append(*builder, "    "); }
        append(*builder, prefix);
        append(*builder, " ");
        append(*builder, brace_statement(stmt));
        it.text = builder_to_string(*builder);
    }
}

parse_loop_line :: (line: Out_Line) -> Const_Line {
    result: Const_Line;
    t := line.text;
    k := line.indent * 4;
    if t.count <= k + 6 { return result; }
    if slice(t, k, 6) != "while " && slice(t, k, 4) != "for " { return result; }

    head_start := k;
    paren      := 0;
    sep_start  := -1;
    while k < t.count {
        c := t[k];
        if c == #char "\"" {
            k += 1;
            while k < t.count {
                if t[k] == #char "\\" { k += 2; continue; }
                if t[k] == #char "\"" { k += 1; break; }
                k += 1;
            }
            continue;
        }
        if c == #char "(" || c == #char "[" { paren += 1; }
        if c == #char ")" || c == #char "]" { paren -= 1; }
        if c == #char "{" && paren == 0 { return result; }
        if c == #char " " && paren == 0 && k + 1 < t.count && t[k+1] == #char " " {
            sep_start = k;
            break;
        }
        k += 1;
    }
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

ambiguous_spacing :: (stmt: string) -> bool {
    k := 0;
    while k < stmt.count {
        c := stmt[k];
        if c == #char "\"" {
            k += 1;
            while k < stmt.count {
                if stmt[k] == #char "\\" { k += 2; continue; }
                if stmt[k] == #char "\"" { k += 1; break; }
                k += 1;
            }
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

normalize_spaces :: (lines: [] Out_Line) {
    for * lines {
        if it.protected || it.text.count == 0 { continue; }
        content := slice(it.text, it.indent * 4, it.text.count - it.indent * 4);
        if content.count == 0 || starts_with(content, "//") { continue; }
        it.text = make_line(it.indent, collapse_whitespace(content));
    }
}

collapse_whitespace :: (s: string) -> string {
    builder: String_Builder;
    k := 0;
    while k < s.count {
        c := s[k];
        if c == #char "\"" {
            append(*builder, c);
            k += 1;
            while k < s.count {
                append(*builder, s[k]);
                if s[k] == #char "\\" && k + 1 < s.count {
                    k += 1;
                    append(*builder, s[k]);
                    k += 1;
                    continue;
                }
                if s[k] == #char "\"" { k += 1; break; }
                k += 1;
            }
            continue;
        }
        if c == #char "/" && k + 1 < s.count && s[k+1] == #char "/" {
            append(*builder, slice(s, k, s.count - k));
            break;
        }
        if c == #char "/" && k + 1 < s.count && s[k+1] == #char "*" {
            end   := k + 2;
            depth := 1;
            while end < s.count && depth > 0 {
                if end + 1 < s.count && s[end] == #char "*" && s[end+1] == #char "/" { depth -= 1; end += 2; continue; }
                if end + 1 < s.count && s[end] == #char "/" && s[end+1] == #char "*" { depth += 1; end += 2; continue; }
                end += 1;
            }
            append(*builder, slice(s, k, end - k));
            k = end;
            continue;
        }
        if c == #char " " || c == #char "\t" {
            m := k;
            while m < s.count && (s[m] == #char " " || s[m] == #char "\t") { m += 1; }
            if m >= s.count { break; }
            if m + 1 < s.count && s[m] == #char "/" && s[m+1] == #char "/" { append(*builder, "  "); }
            else                                                           { append(*builder, " "); }
            k = m;
            continue;
        }
        append(*builder, c);
        k += 1;
    }
    return builder_to_string(*builder);
}

collapse_short_blocks :: (lines: [..] Out_Line) -> [..] Out_Line {
    result: [..] Out_Line;
    i := 0;
    while i < lines.count {
        collapsed, consumed := try_collapse(lines, i);
        if consumed > 0 {
            array_add(*result, collapsed);
            i += consumed;
        } else {
            array_add(*result, lines[i]);
            i += 1;
        }
    }
    return result;
}

try_collapse :: (lines: [] Out_Line, i: s64) -> Out_Line, s64 {
    empty: Out_Line;
    header := lines[i];
    if header.protected { return empty, 0; }
    c := trim(header.text);
    if c.count < 4 { return empty, 0; }
    if c[c.count - 1] != #char "{" { return empty, 0; }
    if !starts_with(c, "if ") && !starts_with(c, "else ") && c != "else {" { return empty, 0; }
    head := strip_trailing(slice(c, 0, c.count - 1));

    stmts: [..] string;
    j := i + 1;
    while j < lines.count {
        b := lines[j];
        if b.protected { return empty, 0; }
        bc := trim(b.text);
        if bc.count == 0 { return empty, 0; }
        if bc == "}" { break; }
        if b.indent != header.indent + 1 { return empty, 0; }
        if bc[bc.count - 1] != #char ";" { return empty, 0; }
        if !simple_statement(bc) { return empty, 0; }
        array_add(*stmts, bc);
        j += 1;
    }
    if j >= lines.count || stmts.count == 0 { return empty, 0; }
    if lines[j].indent != header.indent || lines[j].protected { return empty, 0; }

    builder: String_Builder;
    for 1..header.indent { append(*builder, "    "); }
    append(*builder, head);
    append(*builder, " { ");
    for stmts {
        if it_index > 0 { append(*builder, " "); }
        append(*builder, it);
    }
    append(*builder, " }");
    text := builder_to_string(*builder);
    if text.count > COLLAPSE_WIDTH { return empty, 0; }

    out: Out_Line;
    out.text   = text;
    out.indent = header.indent;
    return out, j - i + 1;
}

simple_statement :: (s: string) -> bool {
    if is_case_line(s) { return false; }
    if starts_with(s, "if ") || starts_with(s, "for ") || starts_with(s, "while ") || starts_with(s, "else") { return false; }
    for i: 0..s.count-1 {
        c := s[i];
        if c == #char "{" || c == #char "}" { return false; }
        if c == #char "/" && i + 1 < s.count && (s[i+1] == #char "/" || s[i+1] == #char "*") { return false; }
    }
    return true;
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

    stmt: string;
    cond: string;
    if kind == .ELSE {
        stmt = slice(t, k, t.count - k);
    } else {
        while k < t.count && t[k] == #char " " { k += 1; }
        cond_start := k;
        paren      := 0;
        sep_start  := -1;
        while k < t.count {
            c := t[k];
            if c == #char "\"" {
                k += 1;
                while k < t.count {
                    if t[k] == #char "\\" { k += 2; continue; }
                    if t[k] == #char "\"" { k += 1; break; }
                    k += 1;
                }
                continue;
            }
            if c == #char "(" || c == #char "[" { paren += 1; }
            if c == #char ")" || c == #char "]" { paren -= 1; }
            if c == #char "{" && paren == 0 { sep_start = k; break; }
            if c == #char " " && paren == 0 && k + 1 < t.count && t[k+1] == #char " " {
                sep_start = k;
                break;
            }
            k += 1;
        }
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

align_if_else_pairs :: (lines: [] Out_Line) {
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

brace_statement :: (stmt: string) -> string {
    if stmt[0] == #char "{" { return normalize_inline_block(stmt); }
    semi := -1;
    k    := 0;
    while k < stmt.count {
        c := stmt[k];
        if c == #char "\"" {
            k += 1;
            while k < stmt.count {
                if stmt[k] == #char "\\" { k += 2; continue; }
                if stmt[k] == #char "\"" { k += 1; break; }
                k += 1;
            }
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
            k += 1;
            while k < stmt.count {
                if stmt[k] == #char "\\" { k += 2; continue; }
                if stmt[k] == #char "\"" { k += 1; break; }
                k += 1;
            }
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
            k += 1;
            while k < inner.count {
                if inner[k] == #char "\\" { k += 2; continue; }
                if inner[k] == #char "\"" { k += 1; break; }
                k += 1;
            }
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

Format_State :: struct {
    curly:               s64;
    pb_indent:           s64;
    pb_stack:            [..] Pb_Entry;
    block_comment_depth: s64;
    here_terminator:     string;
    case_stack:          [..] bool;
}

Pb_Entry :: struct {
    line:   s64;
    counts: bool;
}

is_word_char :: (c: u8) -> bool {
    return (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z")
    || (c >= #char "0" && c <= #char "9") || c == #char "_";
}

is_case_line :: (content: string) -> bool {
    if content.count < 4 { return false; }
    if slice(content, 0, 4) != "case" { return false; }
    if content.count == 4 { return true; }
    return !is_word_char(content[4]);
}

strip_trailing :: (line: string) -> string {
    end := line.count;
    while end > 0 && (line[end - 1] == #char " " || line[end - 1] == #char "\t" || line[end - 1] == #char "\r") { end -= 1; }
    return slice(line, 0, end);
}

scan_line :: (s: *Format_State, line: string, line_index: s64) {
    content  := trim(line);
    saw_case := s.block_comment_depth == 0 && is_case_line(content);

    k := 0;
    while k < line.count {
        c := line[k];

        if s.block_comment_depth > 0 {
            if c == #char "*" && k + 1 < line.count && line[k+1] == #char "/" {
                s.block_comment_depth -= 1;
                k += 2;
                continue;
            }
            if c == #char "/" && k + 1 < line.count && line[k+1] == #char "*" {
                s.block_comment_depth += 1;
                k += 2;
                continue;
            }
            k += 1;
            continue;
        }

        if c == #char "/" && k + 1 < line.count {
            if line[k+1] == #char "/" { break; }
            if line[k+1] == #char "*" { s.block_comment_depth += 1; k += 2; continue; }
        }

        if c == #char "\"" {
            k += 1;
            while k < line.count {
                if line[k] == #char "\\" { k += 2; continue; }
                if line[k] == #char "\"" { k += 1; break; }
                k += 1;
            }
            continue;
        }

        if c == #char "#" && k + 7 <= line.count && slice(line, k + 1, 6) == "string"
        && (k + 7 == line.count || !is_word_char(line[k+7])) {
            m := k + 7;
            while m < line.count && (line[m] == #char " " || line[m] == #char "\t") { m += 1; }
            start := m;
            while m < line.count && is_word_char(line[m]) { m += 1; }
            if m > start { s.here_terminator = slice(line, start, m - start); }
            return;
        }

        if c == {
            case #char "{";
                s.curly += 1;
                array_add(*s.case_stack, false);
            case #char "}";
                s.curly -= 1;
                if s.case_stack.count > 1 { s.case_stack.count -= 1; }
            case #char "("; #through;
            case #char "[";
                counts := s.pb_stack.count == 0 || s.pb_stack[s.pb_stack.count - 1].line != line_index;
                entry: Pb_Entry;
                entry.line   = line_index;
                entry.counts = counts;
                array_add(*s.pb_stack, entry);
                if counts { s.pb_indent += 1; }
            case #char ")"; #through;
            case #char "]";
                if s.pb_stack.count > 0 {
                    top := s.pb_stack[s.pb_stack.count - 1];
                    s.pb_stack.count -= 1;
                    if top.counts { s.pb_indent -= 1; }
                }
        }

        k += 1;
    }

    if saw_case { s.case_stack[s.case_stack.count - 1] = true; }
}
