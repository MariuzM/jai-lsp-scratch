g_entry_file:      string;
g_last_diag_paths: [..]string;

Diag :: struct {
    path:     string;
    line:     s32;
    col:      s32;
    severity: s32;
    message:  string;
}

run_diagnostics :: () {
    if !g_entry_file { return; }
    temporary_directory := platform_temporary_directory();
    if !temporary_directory {
        log_err("could not locate the system temporary directory");
        return;
    }
    output_dir := tprint("%/jai-lsp-scratch", temporary_directory);
    if !make_directory_if_it_does_not_exist(output_dir) {
        log_err("could not create diagnostics output directory %", output_dir);
        return;
    }

    result, output, error_output := run_command(
        g_compiler, g_entry_file, "-exe", "check_bin", "-output_path", output_dir,
        capture_and_return_output = true, timeout_ms = 30000
    );

    combined := tprint("%\n%", output, error_output);
    diags    := parse_compiler_output(combined);

    published: [..]string;
    for diags {
        already := false;
        for p: published if p == it.path already = true;
        if already { continue; }
        array_add(*published, it.path);
        publish_for_path(it.path, diags);
    }

    for old: g_last_diag_paths {
        still := false;
        for p: published if p == old still = true;
        if !still { publish_for_path(old, .[]); }
    }

    {
        push_allocator(g_heap);
        for g_last_diag_paths { free(it); }
        array_reset(*g_last_diag_paths);
        for published { array_add(*g_last_diag_paths, copy_string(it)); }
    }
}

detect_entry_file :: (path: string, content: string) {
    if g_entry_file { return; }
    found := contains(content, "main ::");
    if found {
        push_allocator(g_heap);
        g_entry_file = copy_string(path);
        log_err("entry file detected: %", path);
    }
}

#scope_file

publish_for_path :: (path: string, diags: []Diag) {
    builder: String_Builder;
    print_to_builder(*builder, "{\"uri\":\"%\",\"diagnostics\":[", path_to_uri(path));
    first := true;
    for diags {
        if it.path != path { continue; }
        if !first { append(*builder, ","); }
        first = false;
        print_to_builder(*builder,
            "{\"range\":{\"start\":{\"line\":%,\"character\":%},\"end\":{\"line\":%,\"character\":%}},\"severity\":%,\"source\":\"jai\",\"message\":\"%\"}",
            it.line, it.col, it.line, it.col + 1, it.severity, json_escape(it.message));
    }
    append(*builder, "]}");
    send_notification("textDocument/publishDiagnostics", builder_to_string(*builder));
}

parse_compiler_output :: (s: string) -> [..]Diag {
    diags: [..]Diag;
    remaining := s;
    while remaining.count > 0 {
        line: string;
        newline := find_index_from_left(remaining, #char "\n");
        if newline == -1 {
            line            = remaining;
            remaining.count = 0;
        } else {
            line      = slice(remaining, 0, newline);
            remaining = slice(remaining, newline + 1, remaining.count - newline - 1);
        }

        severity: s32 = 0;
        marker_index := find_index_from_left(line, ": Error: ");
        marker_len   := ": Error: ".count;
        if marker_index != -1 {
            severity = 1;
        } else {
            marker_index = find_index_from_left(line, ": Warning: ");
            marker_len   = ": Warning: ".count;
            if marker_index != -1 { severity = 2; }
        }
        if severity == 0 { continue; }

        location := slice(line, 0, marker_index);
        message  := slice(line, marker_index + marker_len, line.count - marker_index - marker_len);

        colon := last_index_of(location, #char ":");
        if colon == -1 { continue; }
        path     := slice(location, 0, colon);
        line_col := slice(location, colon + 1, location.count - colon - 1);

        comma := find_index_from_left(line_col, #char ",");
        if comma == -1 { continue; }
        line_number, line_ok := string_to_int(slice(line_col, 0, comma), 10, s32);
        col_number, col_ok   := string_to_int(slice(line_col, comma + 1, line_col.count - comma - 1), 10, s32);
        if !line_ok || !col_ok { continue; }

        diag: Diag;
        diag.path     = path;
        diag.line     = max(line_number - 1, 0);
        diag.col      = max(col_number - 1, 0);
        diag.severity = severity;
        diag.message  = message;
        array_add(*diags, diag);
    }
    return diags;
}

last_index_of :: (s: string, c: u8) -> s64 {
    i := s.count - 1;
    while i >= 0 {
        if s[i] == c { return i; }
        i -= 1;
    }
    return -1;
}
