read_message :: () -> string, bool {
    while 1 {
        header_end := find_header_end();
        if header_end != -1 {
            header         := to_view(0, header_end);
            content_length := parse_content_length(header);
            if content_length < 0 {
                log_err("bad header, no Content-Length");
                return "", false;
            }
            total := header_end + 4 + content_length;
            while read_buffer.count < total {
                if !read_more()  return "", false;
            }
            body: string;
            {
                push_allocator(g_heap);
                body = copy_string(to_view(header_end + 4, content_length));
            }
            consume(total);
            return body, true;
        }
        if !read_more()  return "", false;
    }
    return "", false;
}

respond :: (id: Json_Value, result_json: string) {
    body := tprint("{\"jsonrpc\":\"2.0\",\"id\":%,\"result\":%}", json_id_string(id), result_json);
    send_body(body);
}

respond_error :: (id: Json_Value, code: s64, message: string) {
    body := tprint("{\"jsonrpc\":\"2.0\",\"id\":%,\"error\":{\"code\":%,\"message\":\"%\"}}",
        json_id_string(id), code, json_escape(message));
    send_body(body);
}

send_notification :: (method: string, params_json: string) {
    body := tprint("{\"jsonrpc\":\"2.0\",\"method\":\"%\",\"params\":%}", method, params_json);
    send_body(body);
}

log_err :: (format: string, args: .. Any) {
    message := tprint(format, .. args);
    line    := tprint("[jai-lsp-scratch] %\n", message);
    write_all(2, line);
}

write_all :: (fd: s32, s: string) {
    offset := 0;
    while offset < s.count {
        n := Posix.write(fd, s.data + offset, cast(u64)(s.count - offset));
        if n <= 0  break;
        offset += n;
    }
}

#scope_file

read_buffer: [..] u8;

to_view :: (offset: s64, count: s64) -> string {
    s: string;
    s.data  = read_buffer.data + offset;
    s.count = count;
    return s;
}

find_header_end :: () -> s64 {
    i := 0;
    while i + 3 < read_buffer.count {
        if read_buffer[i] == #char "\r" && read_buffer[i+1] == #char "\n"
        && read_buffer[i+2] == #char "\r" && read_buffer[i+3] == #char "\n" {
            return i;
        }
        i += 1;
    }
    return -1;
}

parse_content_length :: (header: string) -> s64 {
    KEY :: "Content-Length:";
    index := find_index_from_left(header, KEY);
    if index == -1  return -1;
    rest := slice(header, index + KEY.count, header.count - index - KEY.count);
    rest = trim(rest);
    end := find_index_from_left(rest, #char "\r");
    if end != -1  rest = slice(rest, 0, end);
    rest = trim(rest);
    value, ok := string_to_int(rest, 10, s64);
    if !ok  return -1;
    return value;
}

read_more :: () -> bool {
    CHUNK :: 65536;
    {
        push_allocator(g_heap);
        array_reserve(*read_buffer, read_buffer.count + CHUNK);
    }
    n := Posix.read(0, read_buffer.data + read_buffer.count, CHUNK);
    if n <= 0  return false;
    read_buffer.count += n;
    return true;
}

consume :: (count: s64) {
    remaining := read_buffer.count - count;
    if remaining > 0  memcpy(read_buffer.data, read_buffer.data + count, remaining);
    read_buffer.count = remaining;
}

send_body :: (body: string) {
    header := tprint("Content-Length: %\r\n\r\n", body.count);
    write_all(1, header);
    write_all(1, body);
}
