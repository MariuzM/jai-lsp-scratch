Doc :: struct {
    path: string;
    text: string;
}

g_docs:            [..] Doc;
g_files:           [..] string;
g_indexed_modules: [..] string;

get_text :: (path: string) -> string, bool {
    index := find_doc(path);
    if index != -1 { return g_docs[index].text, true; }
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

close_doc :: (path: string) {
    index := find_doc(path);
    if index == -1 { return; }
    push_allocator(g_heap);
    free(g_docs[index].path);
    free(g_docs[index].text);
    array_unordered_remove_by_index(*g_docs, index);
}

scan_workspace :: () {
    filenames: [..] string;
    visit_files(g_root, true, *filenames, visit_jai_files);
    count := 0;
    for filenames {
        found_build, _ := contains(it, "/.build/");
        found_out, _   := contains(it, "/build/");
        if found_build || found_out { continue; }
        content, ok := read_entire_file(it);
        if !ok { continue; }
        index_file(it, content);
        detect_entry_file(it, content);
        add_workspace_file(it);
        index_imported_modules(content);
        count += 1;
    }
    log_err("indexed % files, % decls", count, g_decls.count);
}

add_workspace_file :: (path: string) {
    if !ends_with(path, ".jai") { return; }
    for g_files if it == path return;
    push_allocator(g_heap);
    array_add(*g_files, copy_string(path));
}

index_imported_modules :: (content: string) {
    remaining := content;
    while 1 {
        index := find_index_from_left(remaining, "#import");
        if index == -1 { break; }
        remaining = slice(remaining, index + 7, remaining.count - index - 7);
        k := 0;
        while k < remaining.count && remaining[k] == #char " " { k += 1; }
        if k >= remaining.count || remaining[k] != #char "\"" { continue; }
        k += 1;
        start := k;
        while k < remaining.count && remaining[k] != #char "\"" && remaining[k] != #char "\n" { k += 1; }
        if k >= remaining.count || remaining[k] != #char "\"" { continue; }
        index_module(slice(remaining, start, k - start));
    }
}

modules_root :: () -> string {
    return tprint("%/../modules", dir_of(g_compiler));
}

resolve_compiler_path :: () {
    path := g_compiler;

    has_slash, _ := contains(path, #char "/");
    if !has_slash {
        env := Posix.getenv("PATH".data);
        if env {
            remaining := to_string(env);
            while remaining.count > 0 {
                dir   := remaining;
                colon := find_index_from_left(remaining, #char ":");
                if colon == -1 {
                    remaining = "";
                } else {
                    dir       = slice(remaining, 0, colon);
                    remaining = slice(remaining, colon + 1, remaining.count - colon - 1);
                }
                if dir.count == 0 { continue; }
                candidate := tprint("%/%", dir, g_compiler);
                if file_exists(candidate) { path = candidate; break; }
            }
        }
    }

    for 1..8 {
        buffer: [4096] u8;
        n := Posix.readlink(temp_c_string(path), buffer.data, 4096);
        if n <= 0 { break; }
        link: string;
        link.data  = buffer.data;
        link.count = n;
        if link[0] == #char "/" { path = tprint("%", link); }
        else                    { path = tprint("%/%", dir_of(path), link); }
    }

    if path != g_compiler {
        push_allocator(g_heap);
        g_compiler = copy_string(path);
        log_err("compiler resolved to %", g_compiler);
    }
}

uri_to_path :: (uri: string) -> string {
    s := uri;
    if starts_with(s, "file://") { s = slice(s, 7, s.count - 7); }
    builder: String_Builder;
    i := 0;
    while i < s.count {
        c := s[i];
        if c == #char "%" && i + 2 < s.count {
            high := hex_digit(s[i+1]);
            low  := hex_digit(s[i+2]);
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

path_to_uri :: (path: string) -> string {
    builder: String_Builder;
    append(*builder, "file://");
    for i: 0..path.count-1 {
        c := path[i];
        if c == #char " " { append(*builder, "%20"); }
        else              { append(*builder, c); }
    }
    return builder_to_string(*builder);
}

display_path :: (path: string) -> string {
    if g_root.count && starts_with(path, g_root) {
        relative := slice(path, g_root.count, path.count - g_root.count);
        if relative.count && relative[0] == #char "/" { relative = slice(relative, 1, relative.count - 1); }
        return relative;
    }
    marker := "/modules/";
    index  := find_index_from_left(path, marker);
    if index != -1 {
        rest := slice(path, index + marker.count, path.count - index - marker.count);
        return tprint("Jai/%", rest);
    }
    return path;
}

dir_of :: (path: string) -> string {
    i := path.count - 1;
    while i >= 0 {
        if path[i] == #char "/" { return slice(path, 0, i); }
        i -= 1;
    }
    return path;
}

#scope_file

find_doc :: (path: string) -> s64 {
    for g_docs if it.path == path return it_index;
    return -1;
}

visit_jai_files :: (info: *File_Visit_Info, results: *[..] string) {
    if ends_with(info.short_name, ".jai") { array_add(results, copy_string(info.full_name)); }
}

index_module :: (name: string) {
    if name.count == 0 { return; }
    for g_indexed_modules if it == name return;
    {
        push_allocator(g_heap);
        array_add(*g_indexed_modules, copy_string(name));
    }

    base   := modules_root();
    single := tprint("%/%.jai", base, name);
    if file_exists(single) {
        index_module_file(single);
        log_err("indexed module % (single file)", name);
        return;
    }
    dir         := tprint("%/%", base, name);
    module_main := tprint("%/module.jai", dir);
    if !file_exists(module_main) { return; }
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
    if !ok { return; }
    index_file(path, content);
}

hex_digit :: (c: u8) -> s32 {
    if c >= #char "0" && c <= #char "9" { return c - #char "0"; }
    if c >= #char "a" && c <= #char "f" { return c - #char "a" + 10; }
    if c >= #char "A" && c <= #char "F" { return c - #char "A" + 10; }
    return -1;
}
