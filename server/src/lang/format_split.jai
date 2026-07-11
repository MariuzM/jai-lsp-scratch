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

#scope_file

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
            k = skip_string(s, k);
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
