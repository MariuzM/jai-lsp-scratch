handle_message :: (body: string) {
    push_allocator(temp);

    msg, ok := json_parse(body);
    if !ok {
        log_err("failed to parse message (% bytes)", body.count);
        return;
    }

    method     := json_get_string(msg, "method");
    id, has_id := json_get(msg, "id");
    params, _  := json_get_object(msg, "params");

    if method == {
        case "initialize";                  handle_initialize(id, params);
        case "initialized";                 handle_initialized();
        case "shutdown";                    handle_shutdown(id);
        case "exit";                        g_exit = true;
        case "textDocument/didOpen";        handle_did_open(params);
        case "textDocument/didChange";      handle_did_change(params);
        case "textDocument/didSave";        run_diagnostics();
        case "textDocument/didClose";       handle_did_close(params);
        case "textDocument/documentSymbol"; handle_document_symbol(id, params);
        case "textDocument/definition";     handle_definition(id, params);
        case "textDocument/references";     handle_references(id, params);
        case "textDocument/hover";          handle_hover(id, params);
        case "textDocument/completion";     handle_completion(id, params);
        case "textDocument/formatting";     handle_formatting(id, params);
        case "workspace/symbol";            handle_workspace_symbol(id, params);
        case "$/setTrace";                      // ignore
        case "$/cancelRequest";                 // ignore
        case;
            if has_id { respond_error(id, -32601, tprint("method not found: %", method)); }
    }
}

#scope_file

handle_initialize :: (id: Json_Value, params: Json_Value) {
    root     := "";
    root_uri := json_get_string(params, "rootUri");
    if root_uri { root = uri_to_path(root_uri); }
    if !root {
        folders, folders_ok := json_get(params, "workspaceFolders");
        if folders_ok && folders.kind == .ARRAY && folders.elements.count > 0 {
            root = uri_to_path(json_get_string(folders.elements[0], "uri"));
        }
    }
    if !root { root = json_get_string(params, "rootPath"); }

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
    resolve_compiler_path();
    log_err("initialize root=% compiler=%", g_root, g_compiler);

    respond(id, "{\"capabilities\":{\"textDocumentSync\":1,\"hoverProvider\":true,\"definitionProvider\":true,\"referencesProvider\":true,\"documentSymbolProvider\":true,\"workspaceSymbolProvider\":true,\"documentFormattingProvider\":true,\"completionProvider\":{\"triggerCharacters\":[\".\"]}},\"serverInfo\":{\"name\":\"jai-lsp-scratch\",\"version\":\"0.5.0\"}}");
}

handle_shutdown :: (id: Json_Value) {
    g_shutdown = true;
    respond(id, "null");
}

handle_initialized :: () {
    if !g_root { return; }
    scan_workspace();
    run_diagnostics();
}

handle_did_open :: (params: Json_Value) {
    doc, ok := json_get_object(params, "textDocument");
    if !ok { return; }
    path := uri_to_path(json_get_string(doc, "uri"));
    text := json_get_string(doc, "text");
    set_doc(path, text);
    index_file(path, text);
    detect_entry_file(path, text);
    add_workspace_file(path);
    index_imported_modules(text);
}

handle_did_change :: (params: Json_Value) {
    doc, ok := json_get_object(params, "textDocument");
    if !ok { return; }
    path                := uri_to_path(json_get_string(doc, "uri"));
    changes, changes_ok := json_get(params, "contentChanges");
    if !changes_ok || changes.kind != .ARRAY || changes.elements.count == 0 { return; }
    text := json_get_string(changes.elements[changes.elements.count - 1], "text");
    set_doc(path, text);
    index_file(path, text);
    index_imported_modules(text);
}

handle_did_close :: (params: Json_Value) {
    doc, ok := json_get_object(params, "textDocument");
    if !ok { return; }
    close_doc(uri_to_path(json_get_string(doc, "uri")));
}

handle_document_symbol :: (id: Json_Value, params: Json_Value) {
    path  := request_path(params);
    decls := decls_in_file(path);
    builder: String_Builder;
    append(*builder, "[");
    for decls {
        if it_index > 0 { append(*builder, ","); }
        print_to_builder(*builder, "{\"name\":\"%\",\"kind\":%,\"location\":", json_escape(it.name), symbol_kind_number(it.kind));
        append_location(*builder, it);
        append(*builder, "}");
    }
    append(*builder, "]");
    respond(id, builder_to_string(*builder));
}

handle_definition :: (id: Json_Value, params: Json_Value) {
    path            := request_path(params);
    line, character := request_position(params);
    text, ok        := get_text(path);
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
        if members.count > 0 { matches = members; }
    }
    if matches.count > 0 {
        builder: String_Builder;
        append(*builder, "[");
        for matches {
            if it_index > 0 { append(*builder, ","); }
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
            if chosen == -1 || it.line > hits[chosen].line { chosen = it_index; }
        }
    }
    if chosen == -1 { chosen = 0; }
    hit := hits[chosen];
    respond(id, tprint("[{\"uri\":\"%\",\"range\":{\"start\":{\"line\":%,\"character\":%},\"end\":{\"line\":%,\"character\":%}}}]",
        path_to_uri(path), hit.line, hit.col, hit.line, hit.name_end));
}

handle_references :: (id: Json_Value, params: Json_Value) {
    path            := request_path(params);
    line, character := request_position(params);
    text, ok        := get_text(path);
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
    ctx, ctx_ok         := json_get_object(params, "context");
    if ctx_ok {
        value, value_ok := json_get(ctx, "includeDeclaration");
        if value_ok && value.kind == .BOOLEAN { include_declaration = value.boolean; }
    }

    builder: String_Builder;
    append(*builder, "[");
    first := true;
    total := 0;
    for file: g_files {
        file_text, file_ok := get_text(file);
        if !file_ok { continue; }
        total += append_references_in_file(*builder, file, file_text, word, *first, include_declaration);
    }
    append(*builder, "]");
    log_err("references for '%': % locations", word, total);
    respond(id, builder_to_string(*builder));
}

handle_hover :: (id: Json_Value, params: Json_Value) {
    path            := request_path(params);
    line, character := request_position(params);
    text, ok        := get_text(path);
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
        if members.count > 0 { matches = members; }
    }
    if matches.count == 0 {
        respond(id, "null");
        return;
    }
    best := matches[0];
    for matches  if it.path == path  best = it;

    relative := display_path(best.path);
    value    := tprint("```jai\n%\n```\n\n%:%", best.signature, relative, best.line + 1);
    respond(id, tprint("{\"contents\":{\"kind\":\"markdown\",\"value\":\"%\"}}", json_escape(value)));
}

handle_completion :: (id: Json_Value, params: Json_Value) {
    builder: String_Builder;
    append(*builder, "[");
    for g_decls {
        if it_index > 0 { append(*builder, ","); }
        print_to_builder(*builder, "{\"label\":\"%\",\"kind\":%,\"detail\":\"%\"}",
            json_escape(it.name), completion_kind_number(it.kind), json_escape(it.signature));
    }
    append(*builder, "]");
    respond(id, builder_to_string(*builder));
}

handle_formatting :: (id: Json_Value, params: Json_Value) {
    path     := request_path(params);
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
            found, _   := contains(name_lower, query);
            if !found { continue; }
        }
        if !first { append(*builder, ","); }
        first = false;
        print_to_builder(*builder, "{\"name\":\"%\",\"kind\":%,\"location\":", json_escape(it.name), symbol_kind_number(it.kind));
        append_location(*builder, it);
        append(*builder, "}");
    }
    append(*builder, "]");
    respond(id, builder_to_string(*builder));
}

request_path :: (params: Json_Value) -> string {
    doc, ok := json_get_object(params, "textDocument");
    if !ok { return ""; }
    return uri_to_path(json_get_string(doc, "uri"));
}

request_position :: (params: Json_Value) -> s64, s64 {
    position, ok := json_get_object(params, "position");
    if !ok { return -1, -1; }
    line, line_ok      := json_get_int(position, "line");
    character, char_ok := json_get_int(position, "character");
    if !line_ok || !char_ok { return -1, -1; }
    return line, character;
}

word_at :: (text: string, line: s64, character: s64) -> string, bool {
    offset  := 0;
    current := 0;
    while offset < text.count && current < line {
        if text[offset] == #char "\n" { current += 1; }
        offset += 1;
    }
    if current != line { return "", false; }
    position := offset + character;
    if position > text.count { return "", false; }

    is_word :: (c: u8) -> bool {
        return (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z")
        || (c >= #char "0" && c <= #char "9") || c == #char "_";
    }

    start := position;
    while start > offset && is_word(text[start - 1])  start -= 1;
    end := position;
    while end < text.count && text[end] != #char "\n" && is_word(text[end])  end += 1;
    if end <= start { return "", false; }
    dotted := start > 0 && text[start - 1] == #char ".";
    if dotted && start > 1 && is_word(text[start - 2]) { dotted = false; }
    return slice(text, start, end - start), dotted;
}

directive_target :: (path: string, text: string, line: s64, character: s64) -> string {
    line_text := get_line(text, line);

    resolve :: (line_text: string, character: s64, key: string) -> string {
        key_index := find_index_from_left(line_text, key);
        if key_index == -1 { return ""; }
        q1 := -1;
        i  := key_index + key.count;
        while i < line_text.count {
            if line_text[i] == #char "\"" {
                q1 = i;
                break;
            }
            i += 1;
        }
        if q1 == -1 { return ""; }
        q2 := -1;
        i = q1 + 1;
        while i < line_text.count {
            if line_text[i] == #char "\"" {
                q2 = i;
                break;
            }
            i += 1;
        }
        if q2 == -1 { return ""; }
        if character <= q1 || character > q2 { return ""; }
        return slice(line_text, q1 + 1, q2 - q1 - 1);
    }

    loaded := resolve(line_text, character, "#load");
    if loaded {
        target := tprint("%/%", dir_of(path), loaded);
        if file_exists(target) { return target; }
        return "";
    }

    imported := resolve(line_text, character, "#import");
    if imported {
        target := tprint("%/%/module.jai", modules_root(), imported);
        if file_exists(target) { return target; }
        target = tprint("%/%.jai", modules_root(), imported);
        if file_exists(target) { return target; }
    }
    return "";
}

append_references_in_file :: (builder: *String_Builder, path: string, text: string, word: string, first: *bool, include_declaration: bool) -> s64 {
    is_word :: (c: u8) -> bool {
        return (c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z")
        || (c >= #char "0" && c <= #char "9") || c == #char "_";
    }

    found := 0;
    uri   := path_to_uri(path);
    i     := 0;
    line  := 0;
    col   := 0;
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
                if !first.* { append(builder, ","); }
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

symbol_kind_number :: (kind: Decl_Kind) -> s32 {
    if kind == {
        case .PROCEDURE;   return 12;
        case .STRUCT;      return 23;
        case .ENUM;        return 10;
        case .ENUM_MEMBER; return 22;
        case .CONSTANT;    return 14;
        case .VARIABLE;    return 13;
    }
    return 14;
}

completion_kind_number :: (kind: Decl_Kind) -> s32 {
    if kind == {
        case .PROCEDURE;   return 3;
        case .STRUCT;      return 22;
        case .ENUM;        return 13;
        case .ENUM_MEMBER; return 20;
        case .CONSTANT;    return 21;
        case .VARIABLE;    return 6;
    }
    return 21;
}

append_location :: (builder: *String_Builder, decl: Decl) {
    print_to_builder(builder,
        "{\"uri\":\"%\",\"range\":{\"start\":{\"line\":%,\"character\":%},\"end\":{\"line\":%,\"character\":%}}}",
        path_to_uri(decl.path), decl.line, decl.col, decl.line, decl.name_end);
}
