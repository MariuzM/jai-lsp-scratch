INDEX_CACHE_MAGIC   :: "JLSIDX04";
INDEX_CACHE_VERSION :: cast(u32) 2;

g_index_cache_root:   string;
g_index_cache_hits:   s64;
g_index_cache_misses: s64;

Index_Header :: struct {
    path:    string;
    module:  string;
    size:    s64;
    modtime: Apollo_Time;
}

Cache_Reader :: struct {
    data:   string;
    offset: s64;
    ok := true;
}

index_file_cached :: (path: string, module := "", content := "", has_content := false) {
    modtime, size, metadata_ok := file_modtime_and_size(path);
    if metadata_ok && load_index_cache(path, module, modtime, size) {
        g_index_cache_hits += 1;
        return;
    }

    text := content;
    if !has_content {
        ok: bool;
        text, ok = read_entire_file(path);
        if !ok { return; }
    }

    g_index_cache_misses += 1;
    file := index_file(path, text, module, size, modtime);
    if metadata_ok { save_index_cache(file); }
}

log_index_cache_stats :: () {
    log_err("index cache: % hits, % misses", g_index_cache_hits, g_index_cache_misses);
}

encode_index :: (header: Index_Header, decls: []Decl) -> string {
    builder: String_Builder;
    append(*builder, INDEX_CACHE_MAGIC);
    cache_append_value(*builder, INDEX_CACHE_VERSION);
    cache_append_string(*builder, header.path);
    cache_append_string(*builder, header.module);
    cache_append_value(*builder, header.size);
    cache_append_value(*builder, header.modtime.low);
    cache_append_value(*builder, header.modtime.high);
    cache_append_value(*builder, cast(u32) decls.count);
    for decls {
        cache_append_value(*builder, cast(u8) it.kind);
        cache_append_value(*builder, it.line);
        cache_append_value(*builder, it.col);
        cache_append_value(*builder, it.name_end);
        cache_append_string(*builder, it.name);
        cache_append_string(*builder, it.signature);
    }
    return builder_to_string(*builder,, allocator = g_heap);
}

decode_index :: (data: string) -> Index_Header, [..]Decl, bool {
    header: Index_Header;
    decls:  [..]Decl;

    reader: Cache_Reader;
    reader.data = data;

    magic   := cache_read_bytes(*reader, INDEX_CACHE_MAGIC.count);
    version := cache_read_value(*reader, u32);
    count   := cache_read_value(*reader, u32);

    header.path         = cache_read_string(*reader);
    header.module       = cache_read_string(*reader);
    header.size         = cache_read_value(*reader, s64);
    header.modtime.low  = cache_read_value(*reader, u64);
    header.modtime.high = cache_read_value(*reader, s64);

    if !reader.ok || magic != INDEX_CACHE_MAGIC || version != INDEX_CACHE_VERSION || count > cast(u32)(data.count / 21) {
        return header, decls, false;
    }

    decls.allocator = g_heap;
    array_reserve(*decls, count);
    for 1..count {
        decl: Decl;
        decl.kind      = cast(Decl_Kind) cache_read_value(*reader, u8);
        decl.line      = cache_read_value(*reader, s32);
        decl.col       = cache_read_value(*reader, s32);
        decl.name_end  = cache_read_value(*reader, s32);
        decl.name      = cache_read_string(*reader);
        decl.signature = cache_read_string(*reader);
        if !reader.ok || cast(u8) decl.kind > cast(u8) Decl_Kind.VARIABLE { break; }
        array_add(*decls, decl);
    }
    if !reader.ok || decls.count != count || reader.offset != data.count {
        array_reset(*decls);
        return header, decls, false;
    }
    return header, decls, true;
}

#scope_file

load_index_cache :: (path: string, module: string, modtime: Apollo_Time, size: s64) -> bool {
    cache_path := index_cache_path(path);
    if !cache_path { return false; }

    data, ok := read_entire_file(cache_path, log_errors = false,, allocator = g_heap);
    if !ok { return false; }

    header, decls, valid := decode_index(data);
    if !valid || header.path != path || header.module != module || header.size != size
    || header.modtime.low != modtime.low || header.modtime.high != modtime.high {
        array_free(decls);
        free(data,, allocator = g_heap);
        return false;
    }

    install_file_index(path, module, data, decls);
    return true;
}

save_index_cache :: (file: *File_Index) {
    cache_path := index_cache_path(file.path);
    if !cache_path { return; }
    write_entire_file(cache_path, file.blob);
}

index_cache_path :: (path: string) -> string {
    root := index_cache_directory();
    if !root { return ""; }
    return tprint("%/%.idx", root, index_cache_hash(path));
}

index_cache_directory :: () -> string {
    if g_index_cache_root { return g_index_cache_root; }

    temporary_directory := platform_temporary_directory();
    if !temporary_directory { return ""; }

    parent := tprint("%/jai-lsp-scratch", temporary_directory);
    if !make_directory_if_it_does_not_exist(parent) { return ""; }

    root := tprint("%/index-cache-v%", parent, INDEX_CACHE_VERSION);
    if !make_directory_if_it_does_not_exist(root) { return ""; }

    push_allocator(g_heap);
    g_index_cache_root = copy_string(root);
    return g_index_cache_root;
}

index_cache_hash :: (value: string) -> u64 {
    hash: u64 = 14695981039346656037;
    for value {
        hash = (hash ^ cast(u64) it) * 1099511628211;
    }
    return hash;
}

cache_append_value :: (builder: *String_Builder, value: $T) {
    append_by_pointer(builder, *value);
}

cache_append_string :: (builder: *String_Builder, value: string) {
    assert(value.count <= 0xffff_ffff);
    cache_append_value(builder, cast(u32) value.count);
    append(builder, value);
}

cache_read_bytes :: (reader: *Cache_Reader, count: s64) -> string {
    if !reader.ok || count < 0 || reader.offset > reader.data.count - count {
        reader.ok = false;
        return "";
    }
    result := slice(reader.data, reader.offset, count);
    reader.offset += count;
    return result;
}

cache_read_value :: (reader: *Cache_Reader, $T: Type) -> T {
    value: T;
    bytes := cache_read_bytes(reader, size_of(T));
    if reader.ok { memcpy(*value, bytes.data, size_of(T)); }
    return value;
}

cache_read_string :: (reader: *Cache_Reader) -> string {
    count := cache_read_value(reader, u32);
    if !reader.ok { return ""; }
    return cache_read_bytes(reader, count);
}
