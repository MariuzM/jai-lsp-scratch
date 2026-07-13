Json_Kind :: enum {
    NULL;
    BOOLEAN;
    INTEGER;
    FLOAT;
    STRING;
    OBJECT;
    ARRAY;
}

Json_Member :: struct {
    key:   string;
    value: Json_Value;
}

Json_Value :: struct {
    kind:     Json_Kind;
    boolean:  bool;
    integer:  s64;
    number:   float64;
    str:      string;
    members:  [..]Json_Member;
    elements: [..]Json_Value;
}

json_parse :: (s: string) -> Json_Value, bool {
    p: Json_Parser;
    p.s = s;
    value := parse_value(*p, 0);
    skip_whitespace(*p);
    if p.failed || p.pos != p.s.count { return .{}, false; }
    return value, true;
}

json_get :: (v: Json_Value, key: string) -> Json_Value, bool {
    for v.members if it.key == key return it.value, true;
    return .{}, false;
}

json_get_string :: (v: Json_Value, key: string) -> string {
    member, ok := json_get(v, key);
    if !ok || member.kind != .STRING { return ""; }
    return member.str;
}

json_get_int :: (v: Json_Value, key: string) -> s64, bool {
    member, ok := json_get(v, key);
    if !ok || member.kind != .INTEGER { return 0, false; }
    return member.integer, true;
}

json_get_object :: (v: Json_Value, key: string) -> Json_Value, bool {
    member, ok := json_get(v, key);
    if !ok || member.kind != .OBJECT { return .{}, false; }
    return member, true;
}

json_escape :: (s: string) -> string {
    builder: String_Builder;
    for i: 0..s.count-1 {
        c := s[i];
        if c == {
            case #char "\""; append(*builder, "\\\"");
            case #char "\\"; append(*builder, "\\\\");
            case #char "\n"; append(*builder, "\\n");
            case #char "\r"; append(*builder, "\\r");
            case #char "\t"; append(*builder, "\\t");
            case;
                if c < 0x20 {
                    print_to_builder(*builder, "\\u%", formatInt(c, base=16, minimum_digits=4));
                } else {
                    append(*builder, c);
                }
        }
    }
    return builder_to_string(*builder);
}

json_id_string :: (id: Json_Value) -> string {
    if id.kind == {
        case .INTEGER; return tprint("%", id.integer);
        case .STRING;  return tprint("\"%\"", json_escape(id.str));
    }
    return "null";
}

#scope_file

MAX_DEPTH :: 64;

Json_Parser :: struct {
    s:      string;
    pos:    s64;
    failed: bool;
}

peek :: (p: *Json_Parser) -> u8 {
    if p.pos >= p.s.count { return 0; }
    return p.s[p.pos];
}

skip_whitespace :: (p: *Json_Parser) {
    while p.pos < p.s.count {
        c := p.s[p.pos];
        if c != #char " " && c != #char "\t" && c != #char "\n" && c != #char "\r" { break; }
        p.pos += 1;
    }
}

expect :: (p: *Json_Parser, c: u8) -> bool {
    if peek(p) != c { p.failed = true; return false; }
    p.pos += 1;
    return true;
}

parse_value :: (p: *Json_Parser, depth: int) -> Json_Value {
    result: Json_Value;
    if depth > MAX_DEPTH { p.failed = true; return result; }

    skip_whitespace(p);
    c := peek(p);
    if c == {
        case #char "{";
            result = parse_object(p, depth);
        case #char "[";
            result = parse_array(p, depth);
        case #char "\"";
            result.kind = .STRING;
            result.str  = parse_string(p);
        case #char "t";
            if parse_literal(p, "true") { result.kind = .BOOLEAN; result.boolean = true; }
        case #char "f";
            if parse_literal(p, "false") { result.kind = .BOOLEAN; result.boolean = false; }
        case #char "n";
            if parse_literal(p, "null") { result.kind = .NULL; }
        case;
            result = parse_number(p);
    }
    return result;
}

parse_literal :: (p: *Json_Parser, literal: string) -> bool {
    if p.pos + literal.count > p.s.count { p.failed = true; return false; }
    if slice(p.s, p.pos, literal.count) != literal { p.failed = true; return false; }
    p.pos += literal.count;
    return true;
}

parse_object :: (p: *Json_Parser, depth: int) -> Json_Value {
    result: Json_Value;
    result.kind = .OBJECT;
    expect(p, #char "{");
    skip_whitespace(p);
    if peek(p) == #char "}" { p.pos += 1; return result; }
    while !p.failed {
        skip_whitespace(p);
        member: Json_Member;
        member.key = parse_string(p);
        if p.failed { break; }
        skip_whitespace(p);
        if !expect(p, #char ":") { break; }
        member.value = parse_value(p, depth + 1);
        if p.failed { break; }
        array_add(*result.members, member);
        skip_whitespace(p);
        c := peek(p);
        if c == #char "," { p.pos += 1; continue; }
        expect(p, #char "}");
        break;
    }
    return result;
}

parse_array :: (p: *Json_Parser, depth: int) -> Json_Value {
    result: Json_Value;
    result.kind = .ARRAY;
    expect(p, #char "[");
    skip_whitespace(p);
    if peek(p) == #char "]" { p.pos += 1; return result; }
    while !p.failed {
        element := parse_value(p, depth + 1);
        if p.failed { break; }
        array_add(*result.elements, element);
        skip_whitespace(p);
        c := peek(p);
        if c == #char "," { p.pos += 1; continue; }
        expect(p, #char "]");
        break;
    }
    return result;
}

parse_string :: (p: *Json_Parser) -> string {
    if !expect(p, #char "\"") { return ""; }
    builder: String_Builder;
    while p.pos < p.s.count {
        c := p.s[p.pos];
        if c == #char "\"" { p.pos += 1; return builder_to_string(*builder); }
        if c == #char "\\" {
            p.pos += 1;
            if p.pos >= p.s.count { break; }
            e := p.s[p.pos];
            p.pos += 1;
            if e == {
                case #char "\""; append(*builder, "\"");
                case #char "\\"; append(*builder, "\\");
                case #char "/";  append(*builder, "/");
                case #char "b";  append(*builder, "\x08");
                case #char "f";  append(*builder, "\x0c");
                case #char "n";  append(*builder, "\n");
                case #char "r";  append(*builder, "\r");
                case #char "t";  append(*builder, "\t");
                case #char "u";
                    code, ok := parse_hex4(p);
                    if !ok { p.failed = true; return ""; }
                    if code >= 0xD800 && code <= 0xDBFF {
                        if p.pos + 1 < p.s.count && p.s[p.pos] == #char "\\" && p.s[p.pos + 1] == #char "u" {
                            p.pos += 2;
                            low, low_ok := parse_hex4(p);
                            if !low_ok || low < 0xDC00 || low > 0xDFFF {
                                p.failed = true;
                                return "";
                            }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                        } else {
                            code = 0xFFFD;
                        }
                    } else if code >= 0xDC00 && code <= 0xDFFF {
                        code = 0xFFFD;
                    }
                    append_utf8(*builder, code);
                case;
                    p.failed = true;
                    return "";
            }
            continue;
        }
        if c < 0x20 { p.failed = true; return ""; }
        append(*builder, c);
        p.pos += 1;
    }
    p.failed = true;
    return "";
}

parse_hex4 :: (p: *Json_Parser) -> u32, bool {
    if p.pos + 4 > p.s.count { return 0, false; }
    value: u32 = 0;
    for i: 0..3 {
        c := p.s[p.pos + i];
        digit: u32;
        if c >= #char "0" && c <= #char "9"      { digit = c - #char "0"; }
        else if c >= #char "a" && c <= #char "f" { digit = c - #char "a" + 10; }
        else if c >= #char "A" && c <= #char "F" { digit = c - #char "A" + 10; }
        else                                     { return 0, false; }
        value = (value << 4) | digit;
    }
    p.pos += 4;
    return value, true;
}

append_utf8 :: (builder: *String_Builder, code: u32) {
    if code < 0x80 {
        append(builder, cast(u8) code);
    } else if code < 0x800 {
        append(builder, cast(u8)(0xC0 | (code >> 6)));
        append(builder, cast(u8)(0x80 | (code & 0x3F)));
    } else if code < 0x10000 {
        append(builder, cast(u8)(0xE0 | (code >> 12)));
        append(builder, cast(u8)(0x80 | ((code >> 6) & 0x3F)));
        append(builder, cast(u8)(0x80 | (code & 0x3F)));
    } else {
        append(builder, cast(u8)(0xF0 | (code >> 18)));
        append(builder, cast(u8)(0x80 | ((code >> 12) & 0x3F)));
        append(builder, cast(u8)(0x80 | ((code >> 6) & 0x3F)));
        append(builder, cast(u8)(0x80 | (code & 0x3F)));
    }
}

parse_number :: (p: *Json_Parser) -> Json_Value {
    result: Json_Value;
    start := p.pos;
    if peek(p) == #char "-" { p.pos += 1; }
    digits   := 0;
    is_float := false;
    while p.pos < p.s.count {
        c := p.s[p.pos];
        if c >= #char "0" && c <= #char "9" {
            digits += 1;
            p.pos += 1;
        } else if c == #char "." || c == #char "e" || c == #char "E" || c == #char "+" || c == #char "-" {
            is_float = true;
            p.pos += 1;
        } else {
            break;
        }
    }
    if digits == 0 { p.failed = true; return result; }
    token := slice(p.s, start, p.pos - start);
    if is_float {
        value, ok := string_to_float64(token);
        if !ok { p.failed = true; return result; }
        result.kind   = .FLOAT;
        result.number = value;
    } else {
        value, ok, remainder := string_to_int(token, 10, s64);
        if !ok || remainder.count > 0 { p.failed = true; return result; }
        result.kind    = .INTEGER;
        result.integer = value;
    }
    return result;
}
