format_source :: (text: string) -> string {
    split := split_statements(text);
    return format_lines(split);
}

Out_Line :: struct {
    text:      string;
    indent:    s64;
    protected: bool;
}

Format_State :: struct {
    curly:               s64;
    pb_indent:           s64;
    pb_stack:            [..]Pb_Entry;
    block_comment_depth: s64;
    here_terminator:     string;
    case_stack:          [..]bool;
    html_mode:           bool;
    html_depth:          s64;
    html_raw:            string;
}

Pb_Entry :: struct {
    line:   s64;
    counts: bool;
}

make_line :: (level: s64, content: string) -> string {
    builder: String_Builder;
    for 1..level { append(*builder, "    "); }
    append(*builder, content);
    return builder_to_string(*builder);
}

skip_string :: (s: string, index: s64) -> s64 {
    k := index + 1;
    while k < s.count {
        if s[k] == #char "\\" { k += 2; continue; }
        if s[k] == #char "\"" { return k + 1; }
        k += 1;
    }
    return k;
}

is_word_char :: (c: u8) -> bool {
    return (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z")
    || (c >= #char "0" && c <= #char "9") || c == #char "_";
}

has_then_keyword :: (content: string) -> bool {
    i := 0;
    while i + 4 <= content.count {
        if slice(content, i, 4) == "then"
        && (i == 0 || !is_word_char(content[i-1]))
        && (i + 4 == content.count || !is_word_char(content[i+4])) {
            return true;
        }
        i += 1;
    }
    return false;
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

#scope_file

format_lines :: (text: string) -> string {
    lines: [..]Out_Line;

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
            if trim(line) == s.here_terminator {
                out.text          = strip_trailing(line);
                s.here_terminator = "";
                s.html_mode       = false;
            } else if s.html_mode {
                out.text = html_indent_line(*s, line);
            } else {
                out.text = line;
            }
            out.protected = true;
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

    strip_then_before_jump(lines);
    wrap_inline_controls(lines);
    normalize_spaces(lines);
    lines = hoist_imports(lines);
    lines = ensure_import_separation(lines);

    align_groups(lines, .{parse_const_line, ":: ", false});
    align_groups(lines, .{parse_foreign_line, "", false});
    align_groups(lines, .{parse_field_line, ":", true});
    align_groups(lines, .{parse_assign_line, "= ", false});
    align_groups(lines, .{parse_decl_line, ":= ", false});
    align_groups(lines, .{parse_case_line, "", false});
    align_if_else_chains(lines);
    align_groups(lines, .{parse_if_return_line, "", false});

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

normalize_spaces :: (lines: []Out_Line) {
    for * lines {
        if it.protected || it.text.count == 0 { continue; }
        content := slice(it.text, it.indent * 4, it.text.count - it.indent * 4);
        if content.count == 0 || starts_with(content, "//") { continue; }
        it.text = make_line(it.indent, collapse_whitespace(content));
    }
}

collapse_whitespace :: (s: string) -> string {
    builder:         String_Builder;
    bracket_is_type: [..]bool;
    prev:            u8 = 0;
    prev_close_is_type := false;
    k                  := 0;
    while k < s.count {
        c := s[k];
        if c == #char "\"" {
            end := skip_string(s, k);
            append(*builder, slice(s, k, end - k));
            prev = #char "\"";
            k    = end;
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
            prev = #char "/";
            k    = end;
            continue;
        }
        if c == #char " " || c == #char "\t" {
            m := k;
            while m < s.count && (s[m] == #char " " || s[m] == #char "\t") { m += 1; }
            if m >= s.count { break; }
            if m + 1 < s.count && s[m] == #char "/" && s[m+1] == #char "/" { append(*builder, "  "); }
            else if !g_space_after_array_type && prev == #char "]" && prev_close_is_type && is_array_element_start(s[m]) {}
            else { append(*builder, " "); }
            k = m;
            continue;
        }
        if c == #char "[" {
            is_type := prev == 0
            || !(is_word_char(prev) || prev == #char ")" || prev == #char "]" || prev == #char "}" || prev == #char "\"");
            array_add(*bracket_is_type, is_type);
            append(*builder, c);
            prev = c;
            k += 1;
            continue;
        }
        if c == #char "]" {
            prev_close_is_type = false;
            if bracket_is_type.count > 0 {
                prev_close_is_type = bracket_is_type[bracket_is_type.count - 1];
                bracket_is_type.count -= 1;
            }
            if g_space_after_array_type && k + 1 < s.count && is_array_element_start(s[k+1]) {
                append(*builder, "] ");
            } else {
                append(*builder, c);
            }
            prev = c;
            k += 1;
            continue;
        }
        append(*builder, c);
        prev = c;
        k += 1;
    }
    return builder_to_string(*builder);
}

is_array_element_start :: (c: u8) -> bool {
    return (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z") || c == #char "_";
}

hoist_imports :: (lines: [..]Out_Line) -> [..]Out_Line {
    header := 0;
    while header < lines.count {
        line := lines[header];
        if !line.protected {
            content := trim(line.text);
            if content.count > 0 && !starts_with(content, "//") && !starts_with(content, "/*") { break; }
        }
        header += 1;
    }

    imports: [..]Out_Line;
    rest:    [..]Out_Line;
    for i: header..lines.count-1 {
        line := lines[i];
        if !line.protected && line.indent == 0 && is_import_line(line.text) {
            array_add(*imports, line);
            blank: Out_Line;
            array_add(*rest, blank);
        } else {
            array_add(*rest, line);
        }
    }
    if imports.count == 0 { return lines; }

    result: [..]Out_Line;
    for i: 0..header-1 { array_add(*result, lines[i]); }
    for imports { array_add(*result, it); }
    for rest { array_add(*result, it); }
    return result;
}

ensure_import_separation :: (lines: [..]Out_Line) -> [..]Out_Line {
    result: [..]Out_Line;
    for i: 0..lines.count-1 {
        array_add(*result, lines[i]);
        line := lines[i];
        if line.protected || !is_import_line(line.text) { continue; }
        if i + 1 >= lines.count { continue; }
        next := lines[i + 1];
        if !next.protected && next.text.count == 0 { continue; }
        if !next.protected && is_import_line(next.text) { continue; }
        blank: Out_Line;
        array_add(*result, blank);
    }
    return result;
}

is_import_line :: (text: string) -> bool {
    content := trim(text);
    if starts_with(content, "#import") || starts_with(content, "#load") { return true; }
    found, _ := contains(content, ":: #import");

    return found;
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
            k = skip_string(line, k);
            continue;
        }

        if c == #char "#" && k + 7 <= line.count && slice(line, k + 1, 6) == "string"
        && (k + 7 == line.count || !is_word_char(line[k+7])) {
            m := k + 7;
            while m < line.count && (line[m] == #char " " || line[m] == #char "\t") { m += 1; }
            start := m;
            while m < line.count && is_word_char(line[m]) { m += 1; }
            if m > start { s.here_terminator = slice(line, start, m - start); }
            if s.here_terminator == "HTML" {
                s.html_mode  = true;
                s.html_depth = 0;
                s.html_raw   = "";
            }
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
