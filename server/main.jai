#import "Basic";
#import "String";
#import "File";
#import "File_Utilities";
#import "Jai_Lexer";
#import "Process";
Posix :: #import "POSIX";

g_heap: Allocator;
g_root: string;
g_compiler := "jai";
g_shutdown := false;
g_exit := false;

Doc :: struct {
    path: string;
    text: string;
}

g_docs: [..] Doc;
g_files: [..] string;
g_indexed_modules: [..] string;

stderr_logger :: (message: string, data: *void, info: Log_Info) {
    if !message.count  return;
    write_all(2, message);
    if message[message.count - 1] != #char "\n"  write_all(2, "\n");
}

main :: () {
    g_heap = context.allocator;
    context.logger = stderr_logger;
    log_err("jai-lsp-scratch starting");

    while !g_exit {
        body, ok := read_message();
        if !ok  break;
        handle_message(body);
        {
            push_allocator(g_heap);
            free(body);
        }
        reset_temporary_storage();
    }
    log_err("jai-lsp-scratch exiting");
}

log_err :: (format: string, args: .. Any) {
    message := tprint(format, .. args);
    line := tprint("[jai-lsp-scratch] %\n", message);
    write_all(2, line);
}

send_notification :: (method: string, params_json: string) {
    body := tprint("{\"jsonrpc\":\"2.0\",\"method\":\"%\",\"params\":%}", method, params_json);
    send_body(body);
}

path_to_uri :: (path: string) -> string {
    builder: String_Builder;
    append(*builder, "file://");
    for i: 0..path.count-1 {
        c := path[i];
        if c == #char " "  append(*builder, "%20");
        else               append(*builder, c);
    }
    return builder_to_string(*builder);
}

#scope_file

read_buffer: [..] u8;

read_message :: () -> string, bool {
    while 1 {
        header_end := find_header_end();
        if header_end != -1 {
            header := to_view(0, header_end);
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

to_view :: (offset: s64, count: s64) -> string {
    s: string;
    s.data = read_buffer.data + offset;
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

write_all :: (fd: s32, s: string) {
    offset := 0;
    while offset < s.count {
        n := Posix.write(fd, s.data + offset, cast(u64)(s.count - offset));
        if n <= 0  break;
        offset += n;
    }
}

send_body :: (body: string) {
    header := tprint("Content-Length: %\r\n\r\n", body.count);
    write_all(1, header);
    write_all(1, body);
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

handle_message :: (body: string) {
    push_allocator(temp);

    msg, ok := json_parse(body);
    if !ok {
        log_err("failed to parse message (% bytes)", body.count);
        return;
    }

    method := json_get_string(msg, "method");
    id, has_id := json_get(msg, "id");
    params, _ := json_get_object(msg, "params");

    if method == {
        case "initialize";                      handle_initialize(id, params);
        case "initialized";                     handle_initialized();
        case "shutdown";                        g_shutdown = true;  respond(id, "null");
        case "exit";                            g_exit = true;
        case "textDocument/didOpen";            handle_did_open(params);
        case "textDocument/didChange";          handle_did_change(params);
        case "textDocument/didSave";            run_diagnostics();
        case "textDocument/didClose";           handle_did_close(params);
        case "textDocument/documentSymbol";     handle_document_symbol(id, params);
        case "textDocument/definition";         handle_definition(id, params);
        case "textDocument/references";         handle_references(id, params);
        case "textDocument/hover";              handle_hover(id, params);
        case "textDocument/completion";         handle_completion(id, params);
        case "textDocument/formatting";         handle_formatting(id, params);
        case "workspace/symbol";                handle_workspace_symbol(id, params);
        case "$/setTrace";                      // ignore
        case "$/cancelRequest";                 // ignore
        case;
            if has_id  respond_error(id, -32601, tprint("method not found: %", method));
    }
}

handle_initialize :: (id: Json_Value, params: Json_Value) {
    root := "";
    root_uri := json_get_string(params, "rootUri");
    if root_uri  root = uri_to_path(root_uri);
    if !root {
        folders, folders_ok := json_get(params, "workspaceFolders");
        if folders_ok && folders.kind == .ARRAY && folders.elements.count > 0 {
            root = uri_to_path(json_get_string(folders.elements[0], "uri"));
        }
    }
    if !root  root = json_get_string(params, "rootPath");

    options, options_ok := json_get_object(params, "initializationOptions");
    if options_ok {
        compiler := json_get_string(options, "compilerPath");
        if compiler {
            push_allocator(g_heap);
            g_compiler = copy_string(compiler);
        }
    }

    {
        push_allocator(g_heap);
        g_root = copy_string(root);
    }
    log_err("initialize root=% compiler=%", g_root, g_compiler);

    respond(id, "{\"capabilities\":{\"textDocumentSync\":1,\"hoverProvider\":true,\"definitionProvider\":true,\"referencesProvider\":true,\"documentSymbolProvider\":true,\"workspaceSymbolProvider\":true,\"documentFormattingProvider\":true,\"completionProvider\":{\"triggerCharacters\":[\".\"]}},\"serverInfo\":{\"name\":\"jai-lsp-scratch\",\"version\":\"0.1.0\"}}");
}

handle_initialized :: () {
    if !g_root  return;
    scan_workspace();
    run_diagnostics();
}

scan_workspace :: () {
    filenames: [..] string;
    visit_files(g_root, true, *filenames, visit_jai_files);
    count := 0;
    for filenames {
        found_build, _ := contains(it, "/.build/");
        found_out, _ := contains(it, "/build/");
        if found_build || found_out  continue;
        content, ok := read_entire_file(it);
        if !ok  continue;
        index_file(it, content);
        detect_entry_file(it, content);
        add_workspace_file(it);
        index_imported_modules(content);
        count += 1;
    }
    log_err("indexed % files, % decls", count, g_decls.count);
}

visit_jai_files :: (info: *File_Visit_Info, results: *[..] string) {
    if ends_with(info.short_name, ".jai") {
        array_add(results, copy_string(info.full_name));
    }
}

uri_to_path :: (uri: string) -> string {
    s := uri;
    if starts_with(s, "file://")  s = slice(s, 7, s.count - 7);
    builder: String_Builder;
    i := 0;
    while i < s.count {
        c := s[i];
        if c == #char "%" && i + 2 < s.count {
            high := hex_digit(s[i+1]);
            low := hex_digit(s[i+2]);
            if high >= 0 && low >= 0 {
                append(*builder, cast(u8)(high * 16 + low));
                i += 3;
                continue;
            }
        }
        append(*builder, c);
        i += 1;
    }
    return builder_to_string(*builder);
}

hex_digit :: (c: u8) -> s32 {
    if c >= #char "0" && c <= #char "9"  return c - #char "0";
    if c >= #char "a" && c <= #char "f"  return c - #char "a" + 10;
    if c >= #char "A" && c <= #char "F"  return c - #char "A" + 10;
    return -1;
}

find_doc :: (path: string) -> s64 {
    for g_docs  if it.path == path  return it_index;
    return -1;
}

get_text :: (path: string) -> string, bool {
    index := find_doc(path);
    if index != -1  return g_docs[index].text, true;
    content, ok := read_entire_file(path);
    return content, ok;
}

set_doc :: (path: string, text: string) {
    push_allocator(g_heap);
    index := find_doc(path);
    if index == -1 {
        doc: Doc;
        doc.path = copy_string(path);
        doc.text = copy_string(text);
        array_add(*g_docs, doc);
    } else {
        free(g_docs[index].text);
        g_docs[index].text = copy_string(text);
    }
}

handle_did_open :: (params: Json_Value) {
    doc, ok := json_get_object(params, "textDocument");
    if !ok  return;
    path := uri_to_path(json_get_string(doc, "uri"));
    text := json_get_string(doc, "text");
    set_doc(path, text);
    index_file(path, text);
    detect_entry_file(path, text);
    add_workspace_file(path);
    index_imported_modules(text);
}

add_workspace_file :: (path: string) {
    if !ends_with(path, ".jai")  return;
    for g_files  if it == path  return;
    push_allocator(g_heap);
    array_add(*g_files, copy_string(path));
}

modules_root :: () -> string {
    return tprint("%/../modules", dir_of(g_compiler));
}

index_imported_modules :: (content: string) {
    remaining := content;
    while 1 {
        index := find_index_from_left(remaining, "#import");
        if index == -1  break;
        remaining = slice(remaining, index + 7, remaining.count - index - 7);
        k := 0;
        while k < remaining.count && remaining[k] == #char " "  k += 1;
        if k >= remaining.count || remaining[k] != #char "\""  continue;
        k += 1;
        start := k;
        while k < remaining.count && remaining[k] != #char "\"" && remaining[k] != #char "\n"  k += 1;
        if k >= remaining.count || remaining[k] != #char "\""  continue;
        index_module(slice(remaining, start, k - start));
    }
}

index_module :: (name: string) {
    if name.count == 0  return;
    for g_indexed_modules  if it == name  return;
    {
        push_allocator(g_heap);
        array_add(*g_indexed_modules, copy_string(name));
    }

    base := modules_root();
    single := tprint("%/%.jai", base, name);
    if file_exists(single) {
        index_module_file(single);
        log_err("indexed module % (single file)", name);
        return;
    }
    dir := tprint("%/%", base, name);
    module_main := tprint("%/module.jai", dir);
    if !file_exists(module_main)  return;
    filenames: [..] string;
    visit_files(dir, true, *filenames, visit_jai_files);
    count := 0;
    for filenames {
        index_module_file(it);
        count += 1;
    }
    log_err("indexed module % (% files)", name, count);
}

index_module_file :: (path: string) {
    content, ok := read_entire_file(path);
    if !ok  return;
    index_file(path, content);
}

handle_did_change :: (params: Json_Value) {
    doc, ok := json_get_object(params, "textDocument");
    if !ok  return;
    path := uri_to_path(json_get_string(doc, "uri"));
    changes, changes_ok := json_get(params, "contentChanges");
    if !changes_ok || changes.kind != .ARRAY || changes.elements.count == 0  return;
    text := json_get_string(changes.elements[changes.elements.count - 1], "text");
    set_doc(path, text);
    index_file(path, text);
    index_imported_modules(text);
}

handle_did_close :: (params: Json_Value) {
    doc, ok := json_get_object(params, "textDocument");
    if !ok  return;
    path := uri_to_path(json_get_string(doc, "uri"));
    index := find_doc(path);
    if index != -1 {
        push_allocator(g_heap);
        free(g_docs[index].path);
        free(g_docs[index].text);
        array_unordered_remove_by_index(*g_docs, index);
    }
}

request_path :: (params: Json_Value) -> string {
    doc, ok := json_get_object(params, "textDocument");
    if !ok  return "";
    return uri_to_path(json_get_string(doc, "uri"));
}

request_position :: (params: Json_Value) -> s64, s64 {
    position, ok := json_get_object(params, "position");
    if !ok  return -1, -1;
    line, line_ok := json_get_int(position, "line");
    character, char_ok := json_get_int(position, "character");
    if !line_ok || !char_ok  return -1, -1;
    return line, character;
}

word_at :: (text: string, line: s64, character: s64) -> string, bool {
    offset := 0;
    current := 0;
    while offset < text.count && current < line {
        if text[offset] == #char "\n"  current += 1;
        offset += 1;
    }
    if current != line  return "", false;
    position := offset + character;
    if position > text.count  return "", false;

    is_word :: (c: u8) -> bool {
        return (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z")
            || (c >= #char "0" && c <= #char "9") || c == #char "_";
    }

    start := position;
    while start > offset && is_word(text[start - 1])  start -= 1;
    end := position;
    while end < text.count && text[end] != #char "\n" && is_word(text[end])  end += 1;
    if end <= start  return "", false;
    dotted := start > 0 && text[start - 1] == #char ".";
    if dotted && start > 1 && is_word(text[start - 2])  dotted = false;
    return slice(text, start, end - start), dotted;
}

symbol_kind_number :: (kind: Decl_Kind) -> s32 {
    if kind == {
        case .PROCEDURE;    return 12;
        case .STRUCT;       return 23;
        case .ENUM;         return 10;
        case .ENUM_MEMBER;  return 22;
        case .CONSTANT;     return 14;
        case .VARIABLE;     return 13;
    }
    return 14;
}

completion_kind_number :: (kind: Decl_Kind) -> s32 {
    if kind == {
        case .PROCEDURE;    return 3;
        case .STRUCT;       return 22;
        case .ENUM;         return 13;
        case .ENUM_MEMBER;  return 20;
        case .CONSTANT;     return 21;
        case .VARIABLE;     return 6;
    }
    return 21;
}

append_location :: (builder: *String_Builder, decl: Decl) {
    print_to_builder(builder,
        "{\"uri\":\"%\",\"range\":{\"start\":{\"line\":%,\"character\":%},\"end\":{\"line\":%,\"character\":%}}}",
        path_to_uri(decl.path), decl.line, decl.col, decl.line, decl.name_end);
}

handle_document_symbol :: (id: Json_Value, params: Json_Value) {
    path := request_path(params);
    decls := decls_in_file(path);
    builder: String_Builder;
    append(*builder, "[");
    for decls {
        if it_index > 0  append(*builder, ",");
        print_to_builder(*builder, "{\"name\":\"%\",\"kind\":%,\"location\":", json_escape(it.name), symbol_kind_number(it.kind));
        append_location(*builder, it);
        append(*builder, "}");
    }
    append(*builder, "]");
    respond(id, builder_to_string(*builder));
}

handle_definition :: (id: Json_Value, params: Json_Value) {
    path := request_path(params);
    line, character := request_position(params);
    text, ok := get_text(path);
    if !ok || line < 0 {
        respond(id, "null");
        return;
    }

    directive := directive_target(path, text, line, character);
    if directive {
        respond(id, tprint("[{\"uri\":\"%\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":0}}}]",
            path_to_uri(directive)));
        return;
    }

    word, dotted := word_at(text, line, character);
    if !word {
        respond(id, "null");
        return;
    }

    matches := find_decls(word);
    if dotted {
        members: [..] Decl;
        for matches  if it.kind == .ENUM_MEMBER  array_add(*members, it);
        if members.count > 0  matches = members;
    }
    if matches.count > 0 {
        builder: String_Builder;
        append(*builder, "[");
        for matches {
            if it_index > 0  append(*builder, ",");
            append_location(*builder, it);
        }
        append(*builder, "]");
        respond(id, builder_to_string(*builder));
        return;
    }

    hits := find_local_decl_sites(text, word);
    if hits.count == 0 {
        respond(id, "null");
        return;
    }
    chosen := -1;
    for hits {
        if it.line <= cast(s32) line {
            if chosen == -1 || it.line > hits[chosen].line  chosen = it_index;
        }
    }
    if chosen == -1  chosen = 0;
    hit := hits[chosen];
    respond(id, tprint("[{\"uri\":\"%\",\"range\":{\"start\":{\"line\":%,\"character\":%},\"end\":{\"line\":%,\"character\":%}}}]",
        path_to_uri(path), hit.line, hit.col, hit.line, hit.name_end));
}

directive_target :: (path: string, text: string, line: s64, character: s64) -> string {
    line_text := get_line(text, line);

    resolve :: (line_text: string, character: s64, key: string) -> string {
        key_index := find_index_from_left(line_text, key);
        if key_index == -1  return "";
        q1 := -1;
        i := key_index + key.count;
        while i < line_text.count {
            if line_text[i] == #char "\"" { q1 = i; break; }
            i += 1;
        }
        if q1 == -1  return "";
        q2 := -1;
        i = q1 + 1;
        while i < line_text.count {
            if line_text[i] == #char "\"" { q2 = i; break; }
            i += 1;
        }
        if q2 == -1  return "";
        if character <= q1 || character > q2  return "";
        return slice(line_text, q1 + 1, q2 - q1 - 1);
    }

    loaded := resolve(line_text, character, "#load");
    if loaded {
        target := tprint("%/%", dir_of(path), loaded);
        if file_exists(target)  return target;
        return "";
    }

    imported := resolve(line_text, character, "#import");
    if imported {
        modules := tprint("%/../modules", dir_of(g_compiler));
        target := tprint("%/%/module.jai", modules, imported);
        if file_exists(target)  return target;
        target = tprint("%/%.jai", modules, imported);
        if file_exists(target)  return target;
    }
    return "";
}

display_path :: (path: string) -> string {
    if g_root.count && starts_with(path, g_root) {
        relative := slice(path, g_root.count, path.count - g_root.count);
        if relative.count && relative[0] == #char "/"  relative = slice(relative, 1, relative.count - 1);
        return relative;
    }
    marker := "/modules/";
    index := find_index_from_left(path, marker);
    if index != -1 {
        rest := slice(path, index + marker.count, path.count - index - marker.count);
        return tprint("Jai/%", rest);
    }
    return path;
}

dir_of :: (path: string) -> string {
    i := path.count - 1;
    while i >= 0 {
        if path[i] == #char "/"  return slice(path, 0, i);
        i -= 1;
    }
    return path;
}

handle_references :: (id: Json_Value, params: Json_Value) {
    path := request_path(params);
    line, character := request_position(params);
    text, ok := get_text(path);
    if !ok || line < 0 {
        respond(id, "[]");
        return;
    }
    word := word_at(text, line, character);
    if !word {
        respond(id, "[]");
        return;
    }

    include_declaration := true;
    ctx, ctx_ok := json_get_object(params, "context");
    if ctx_ok {
        value, value_ok := json_get(ctx, "includeDeclaration");
        if value_ok && value.kind == .BOOLEAN  include_declaration = value.boolean;
    }

    builder: String_Builder;
    append(*builder, "[");
    first := true;
    total := 0;
    for file: g_files {
        file_text, file_ok := get_text(file);
        if !file_ok  continue;
        total += append_references_in_file(*builder, file, file_text, word, *first, include_declaration);
    }
    append(*builder, "]");
    log_err("references for '%': % locations", word, total);
    respond(id, builder_to_string(*builder));
}

append_references_in_file :: (builder: *String_Builder, path: string, text: string, word: string, first: *bool, include_declaration: bool) -> s64 {
    is_word :: (c: u8) -> bool {
        return (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z")
            || (c >= #char "0" && c <= #char "9") || c == #char "_";
    }

    found := 0;
    uri := path_to_uri(path);
    i := 0;
    line := 0;
    col := 0;
    while i < text.count {
        c := text[i];
        if c == #char "\n" {
            line += 1;
            col = 0;
            i += 1;
            continue;
        }
        if is_word(c) && (i == 0 || !is_word(text[i-1])) && i + word.count <= text.count
           && slice(text, i, word.count) == word
           && (i + word.count == text.count || !is_word(text[i + word.count])) {
            skip := false;
            if !include_declaration {
                for g_decls {
                    if it.name == word && it.path == path && it.line == line && it.col == col {
                        skip = true;
                        break;
                    }
                }
            }
            if !skip {
                if !first.*  append(builder, ",");
                first.* = false;
                print_to_builder(builder,
                    "{\"uri\":\"%\",\"range\":{\"start\":{\"line\":%,\"character\":%},\"end\":{\"line\":%,\"character\":%}}}",
                    uri, line, col, line, col + word.count);
                found += 1;
            }
            i += word.count;
            col += word.count;
            continue;
        }
        i += 1;
        col += 1;
    }
    return found;
}

handle_hover :: (id: Json_Value, params: Json_Value) {
    path := request_path(params);
    line, character := request_position(params);
    text, ok := get_text(path);
    if !ok || line < 0 {
        respond(id, "null");
        return;
    }
    word, dotted := word_at(text, line, character);
    if !word {
        respond(id, "null");
        return;
    }
    matches := find_decls(word);
    if dotted {
        members: [..] Decl;
        for matches  if it.kind == .ENUM_MEMBER  array_add(*members, it);
        if members.count > 0  matches = members;
    }
    if matches.count == 0 {
        respond(id, "null");
        return;
    }
    best := matches[0];
    for matches  if it.path == path  best = it;

    relative := display_path(best.path);
    value := tprint("```jai\n%\n```\n\n%:%", best.signature, relative, best.line + 1);
    respond(id, tprint("{\"contents\":{\"kind\":\"markdown\",\"value\":\"%\"}}", json_escape(value)));
}

handle_completion :: (id: Json_Value, params: Json_Value) {
    builder: String_Builder;
    append(*builder, "[");
    for g_decls {
        if it_index > 0  append(*builder, ",");
        print_to_builder(*builder, "{\"label\":\"%\",\"kind\":%,\"detail\":\"%\"}",
            json_escape(it.name), completion_kind_number(it.kind), json_escape(it.signature));
    }
    append(*builder, "]");
    respond(id, builder_to_string(*builder));
}

handle_formatting :: (id: Json_Value, params: Json_Value) {
    path := request_path(params);
    text, ok := get_text(path);
    if !ok {
        respond(id, "null");
        return;
    }
    formatted := format_source(text);
    if formatted == text {
        respond(id, "[]");
        return;
    }
    line_count := 0;
    for i: 0..text.count-1  if text[i] == #char "\n"  line_count += 1;
    respond(id, tprint(
        "[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":%,\"character\":0}},\"newText\":\"%\"}]",
        line_count + 1, json_escape(formatted)));
}

handle_workspace_symbol :: (id: Json_Value, params: Json_Value) {
    query := to_lower_copy(json_get_string(params, "query"));
    builder: String_Builder;
    append(*builder, "[");
    first := true;
    for g_decls {
        if query {
            name_lower := to_lower_copy(it.name);
            found, _ := contains(name_lower, query);
            if !found  continue;
        }
        if !first  append(*builder, ",");
        first = false;
        print_to_builder(*builder, "{\"name\":\"%\",\"kind\":%,\"location\":", json_escape(it.name), symbol_kind_number(it.kind));
        append_location(*builder, it);
        append(*builder, "}");
    }
    append(*builder, "]");
    respond(id, builder_to_string(*builder));
}

#load "json.jai";
#load "index.jai";
#load "check.jai";
#load "format.jai";
