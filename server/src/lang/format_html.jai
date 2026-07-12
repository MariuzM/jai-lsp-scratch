html_indent_line :: (s: *Format_State, line: string) -> string {
    content := trim(line);
    if content.count == 0 { return ""; }

    if s.html_raw.count > 0 {
        closing := tprint("</%", s.html_raw);
        if starts_with(to_lower_copy(content), closing) {
            s.html_raw = "";
            if s.html_depth > 0 then s.html_depth -= 1;
        }
        return html_line(s.html_depth, content);
    }

    lead_close := 0;
    net        := 0;
    seen_open  := false;
    raw_tag    := "";

    k := 0;
    while k < content.count {
        if content[k] != #char "<" {
            k += 1;
            continue;
        }
        if k + 1 >= content.count { break; }
        next := content[k + 1];
        if next == #char "!" {
            while k < content.count && content[k] != #char ">" { k += 1; }
            continue;
        }
        if next == #char "/" {
            name := html_tag_name(content, k + 2);
            if name == raw_tag { raw_tag = ""; }
            net -= 1;
            if !seen_open then lead_close += 1;
            while k < content.count && content[k] != #char ">" { k += 1; }
            continue;
        }
        name := html_tag_name(content, k + 1);
        if name.count == 0 {
            k += 1;
            continue;
        }
        end := k;
        while end < content.count && content[end] != #char ">" { end += 1; }
        self_closing := end > 0 && end < content.count && content[end - 1] == #char "/";
        is_void      := false;
        for HTML_VOID_TAGS { if it == name then is_void = true; }
        if !self_closing && !is_void {
            net += 1;
            seen_open = true;
            if name == "style" || name == "script" then raw_tag = name;
        }
        k = end;
    }

    line_depth := s.html_depth - lead_close;
    if line_depth < 0 then line_depth = 0;
    s.html_depth += net;
    if s.html_depth < 0 then s.html_depth = 0;
    if raw_tag.count > 0 { s.html_raw = raw_tag; }
    return html_line(line_depth, content);
}

#scope_file

HTML_VOID_TAGS :: string.["meta", "img", "br", "hr", "input", "link", "source", "area", "base", "col", "embed", "param", "track", "wbr"];

html_tag_name :: (content: string, start: s64) -> string {
    k := start;
    while k < content.count {
        c  := content[k];
        ok := (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z") || (c >= #char "0" && c <= #char "9") || c == #char "-";
        if !ok { break; }
        k += 1;
    }
    if k == start { return ""; }
    return to_lower_copy(slice(content, start, k - start));
}

html_line :: (depth: s64, content: string) -> string {
    builder: String_Builder;
    for 1..depth { append(*builder, "    "); }
    append(*builder, content);
    return builder_to_string(*builder);
}
