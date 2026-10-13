WRAP_WIDTH :: 100;

Wrap_Expr :: struct {
    segments: [..]Wrap_Segment;
}

Wrap_Segment :: struct {
    text:      string;
    is_group:  bool;
    open:      u8;
    close:     u8;
    breakable: bool;
    items:     [..]Wrap_Expr;
}

wrap_long_statements :: (lines: [..]Out_Line) -> [..]Out_Line {
    result: [..]Out_Line;
    i := 0;
    while i < lines.count {
        end, ok := wrappable_extent(lines, i);
        if !ok {
            array_add(*result, lines[i]);
            i += 1;
            continue;
        }

        joined: String_Builder;
        last: u8 = 0;
        for k: i..end {
            content := trim(lines[k].text);
            if content.count == 0 { continue; }
            if last != 0 && !is_open_bracket(last) && !is_close_bracket(content[0]) { append(*joined, " "); }
            append(*joined, content);
            last = content[content.count - 1];
        }
        text := builder_to_string(*joined);

        k    := 0;
        expr := parse_wrap_expr(text, *k, true);
        flat := flat_wrap_expr(expr);
        if lines[i].indent * 4 + flat.count > WRAP_WIDTH && last_breakable_group(expr) < 0 {
            for k: i..end { array_add(*result, lines[k]); }
        } else {
            layout_wrap_expr(*result, expr, lines[i].indent, "", "");
        }
        i = end + 1;
    }
    return result;
}

#scope_file

wrappable_extent :: (lines: []Out_Line, i: s64) -> s64, bool {
    first := lines[i];
    if first.protected || first.text.count == 0 { return -1, false; }
    head := trim(first.text);
    if starts_with(head, "//") || is_case_line(head) { return -1, false; }
    if continues_previous(lines, i) { return -1, false; }

    stack: [..]u8;
    stack.allocator = temp;
    for k: i..lines.count-1 {
        line := lines[k];
        if line.protected { return -1, false; }
        content := trim(line.text);
        found_string, _ := contains(content, "#string");
        if found_string { return -1, false; }

        m := 0;
        while m < content.count {
            c := content[m];
            if c == #char "\"" {
                m = skip_string(content, m);
                continue;
            }
            if c == #char "/" && m + 1 < content.count && (content[m+1] == #char "/" || content[m+1] == #char "*") {
                return -1, false;
            }
            if c == #char "," {
                n := m + 1;
                while n < content.count && content[n] == #char " " { n += 1; }
                if n < content.count && content[n] == #char "," { return -1, false; }
            }
            if c == #char "(" || c == #char "[" {
                array_add(*stack, c);
            } else if c == #char "{" {
                if m == 0 || content[m-1] != #char "." { return -1, false; }
                array_add(*stack, c);
            } else if is_close_bracket(c) {
                if stack.count == 0 || matching_close(stack[stack.count - 1]) != c { return -1, false; }
                stack.count -= 1;
            }
            m += 1;
        }

        if stack.count == 0 {
            if content.count == 0 || content[content.count - 1] != #char ";" { return -1, false; }
            if k == i && first.text.count <= WRAP_WIDTH { return -1, false; }
            return k, true;
        }
    }
    return -1, false;
}

continues_previous :: (lines: []Out_Line, i: s64) -> bool {
    j := i - 1;
    while j >= 0 && !lines[j].protected && trim(lines[j].text).count == 0 { j -= 1; }
    if j < 0 || lines[j].protected { return false; }
    content := trim(lines[j].text);
    if starts_with(content, "//") { return false; }
    c := content[content.count - 1];
    for cast([]u8) "+-*/%|&=,([.<>!^~" { if c == it { return true; } }
    return false;
}

is_open_bracket :: (c: u8) -> bool {
    return c == #char "(" || c == #char "[" || c == #char "{";
}

is_close_bracket :: (c: u8) -> bool {
    return c == #char ")" || c == #char "]" || c == #char "}";
}

matching_close :: (c: u8) -> u8 {
    if c == #char "(" { return #char ")"; }
    if c == #char "[" { return #char "]"; }
    return #char "}";
}

parse_wrap_expr :: (s: string, k: *s64, top: bool) -> Wrap_Expr {
    expr: Wrap_Expr;
    start := k.*;
    while k.* < s.count {
        c := s[k.*];
        if c == #char "\"" {
            k.* = skip_string(s, k.*);
            continue;
        }
        if is_close_bracket(c) || (c == #char "," && !top && !is_cast_comma(s, k.*)) { break; }
        if is_open_bracket(c) {
            add_wrap_text(*expr, slice(s, start, k.* - start));
            array_add(*expr.segments, parse_wrap_group(s, k));
            start = k.*;
            continue;
        }
        k.* += 1;
    }
    add_wrap_text(*expr, slice(s, start, k.* - start));

    if expr.segments.count > 0 && !expr.segments[0].is_group {
        expr.segments[0].text = trim_left(expr.segments[0].text);
    }
    if expr.segments.count > 0 && !peek(expr.segments).is_group {
        peek_pointer(expr.segments).text = trim_right(peek(expr.segments).text);
    }
    n := 0;
    while n < expr.segments.count {
        if !expr.segments[n].is_group && expr.segments[n].text.count == 0 {
            array_ordered_remove_by_index(*expr.segments, n);
        } else {
            n += 1;
        }
    }
    return expr;
}

is_cast_comma :: (s: string, k: s64) -> bool {
    end := k;
    while end > 0 && s[end-1] == #char " " { end -= 1; }
    start := end;
    while start > 0 && is_word_char(s[start-1]) { start -= 1; }
    if start == end { return false; }
    if slice(s, start, end - start) == "cast" && (start == 0 || !is_word_char(s[start-1])) { return true; }
    return start > 0 && s[start-1] == #char "," && is_cast_comma(s, start - 1);
}

add_wrap_text :: (expr: *Wrap_Expr, text: string) {
    if text.count == 0 { return; }
    segment: Wrap_Segment;
    segment.text = text;
    array_add(*expr.segments, segment);
}

parse_wrap_group :: (s: string, k: *s64) -> Wrap_Segment {
    start := k.*;
    group: Wrap_Segment;
    group.is_group  = true;
    group.open      = s[k.*];
    group.close     = matching_close(group.open);
    group.breakable = is_breakable_open(s, k.*);
    k.* += 1;

    while k.* < s.count {
        item := parse_wrap_expr(s, k, false);
        if item.segments.count > 0 { array_add(*group.items, item); }
        if k.* >= s.count { break; }
        c := s[k.*];
        k.* += 1;
        if c != #char "," { break; }
    }
    group.text = slice(s, start, k.* - start);
    return group;
}

is_breakable_open :: (s: string, k: s64) -> bool {
    if k == 0 { return false; }
    prev := s[k-1];
    if s[k] != #char "(" { return prev == #char "."; }
    if !is_word_char(prev) { return false; }

    start := k;
    while start > 0 && is_word_char(s[start-1]) { start -= 1; }
    if start > 0 && (s[start-1] == #char "#" || s[start-1] == #char ",") { return false; }
    word := slice(s, start, k - start);
    for string.["cast", "xx", "if", "ifx", "then", "else", "while", "for", "return", "case", "defer", "using"] {
        if word == it { return false; }
    }
    return true;
}

last_breakable_group :: (expr: Wrap_Expr) -> s64 {
    for < expr.segments {
        if it.is_group && it.breakable && it.items.count > 0 { return it_index; }
    }
    return -1;
}

flat_wrap_expr :: (expr: Wrap_Expr) -> string {
    builder: String_Builder;
    append_flat_segments(*builder, expr, 0, expr.segments.count);
    return builder_to_string(*builder);
}

append_flat_segments :: (builder: *String_Builder, expr: Wrap_Expr, from: s64, to: s64) {
    for n: from..to-1 {
        segment := expr.segments[n];
        if !segment.is_group || !segment.breakable {
            append(builder, segment.text);
            continue;
        }
        append(builder, segment.open);
        for segment.items {
            if it_index > 0 { append(builder, ", "); }
            append_flat_segments(builder, it, 0, it.segments.count);
        }
        append(builder, segment.close);
    }
}

layout_wrap_expr :: (out: *[..]Out_Line, expr: Wrap_Expr, indent: s64, head: string, tail: string) {
    flat := tprint("%1%2%3", head, flat_wrap_expr(expr), tail);
    g    := last_breakable_group(expr);
    if indent * 4 + flat.count <= WRAP_WIDTH || g < 0 {
        add_wrap_line(out, indent, flat);
        return;
    }

    group := expr.segments[g];
    pre: String_Builder;
    append(*pre, head);
    append_flat_segments(*pre, expr, 0, g);
    append(*pre, group.open);
    post: String_Builder;
    append(*post, group.close);
    append_flat_segments(*post, expr, g + 1, expr.segments.count);
    append(*post, tail);

    if group.items.count == 1 && last_breakable_group(group.items[0]) >= 0 {
        layout_wrap_expr(out, group.items[0], indent, builder_to_string(*pre), builder_to_string(*post));
        return;
    }

    add_wrap_line(out, indent, builder_to_string(*pre));
    for group.items { layout_wrap_expr(out, it, indent + 1, "", ","); }
    add_wrap_line(out, indent, builder_to_string(*post));
}

add_wrap_line :: (out: *[..]Out_Line, indent: s64, content: string) {
    line: Out_Line;
    line.text   = make_line(indent, content);
    line.indent = indent;
    array_add(out, line);
}
