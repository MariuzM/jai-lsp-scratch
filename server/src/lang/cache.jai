INDEX_CACHE_MAGIC   :: "JLSIDX03";
INDEX_CACHE_VERSION :: cast(u32) 1;

g_index_cache_root:   string;
g_index_cache_hits:   s64;
g_index_cache_misses: s64;

Cached_Decl :: struct {
    name:            string;
    line:            s32;
    col:             s32;
    name_end:        s32;
    kind:            Decl_Kind;
    signature:       string;
    completion_base: string;
}

Cache_Reader :: struct {
    data:   string;
    offset: s64;
    ok := true;
}

index_file_content_cached :: (path: string, content: string, module := "") {
    modtime, size, metadata_ok := file_modtime_and_size(path);
    if metadata_ok && load_index_cache(path, module, modtime, size) {
        g_index_cache_hits += 1;
        return;
    }

    g_index_cache_misses += 1;
    first_decl := index_file(path, content, module);
    if metadata_ok { save_index_cache(path, module, modtime, size, first_decl); }
}

index_file_disk_cached :: (path: string, module := "") {
    modtime, size, metadata_ok := file_modtime_and_size(path);
    if metadata_ok && load_index_cache(path, module, modtime, size) {
        g_index_cache_hits += 1;
        return;
    }

    content, ok := read_entire_file(path);
    if !ok { return; }

    g_index_cache_misses += 1;
    first_decl := index_file(path, content, module);
    if metadata_ok { save_index_cache(path, module, modtime, size, first_decl); }
}

log_index_cache_stats :: () {
    log_err("index cache: % hits, % misses", g_index_cache_hits, g_index_cache_misses);
}

#scope_file

load_index_cache :: (path: string, module: string, modtime: Apollo_Time, size: s64) -> bool {
    cache_path := index_cache_path(path);
    if !cache_path { return false; }

    data, ok := read_entire_file(cache_path, log_errors = false);
    if !ok { return false; }

    reader: Cache_Reader;
    reader.data = data;

    magic             := cache_read_bytes(*reader, INDEX_CACHE_MAGIC.count);
    version           := cache_read_value(*reader, u32);
    cached_path       := cache_read_string(*reader);
    cached_module     := cache_read_string(*reader);
    cached_size       := cache_read_value(*reader, s64);
    cached_low        := cache_read_value(*reader, u64);
    cached_high       := cache_read_value(*reader, s64);
    declaration_count := cache_read_value(*reader, u32);

    if !reader.ok || magic != INDEX_CACHE_MAGIC || version != INDEX_CACHE_VERSION
    || cached_path != path || cached_module != module || cached_size != size
    || cached_low != modtime.low || cached_high != modtime.high
    || declaration_count > cast(u32)(data.count / 17) {
        return false;
    }

    cached: [..]Cached_Decl;
    for 1..declaration_count {
        item: Cached_Decl;
        item.kind            = cast(Decl_Kind) cache_read_value(*reader, u8);
        item.line            = cache_read_value(*reader, s32);
        item.col             = cache_read_value(*reader, s32);
        item.name_end        = cache_read_value(*reader, s32);
        item.name            = cache_read_string(*reader);
        item.signature       = cache_read_string(*reader);
        item.completion_base = cache_read_string(*reader);
        if !reader.ok || cast(u8)item.kind > cast(u8)Decl_Kind.VARIABLE { return false; }
        array_add(*cached, item);
    }
    if !reader.ok || reader.offset != data.count { return false; }

    prepare_file_index(path);
    push_allocator(g_heap);
    for cached {
        decl: Decl;
        decl.name            = copy_string(it.name);
        decl.path            = copy_string(path);
        decl.line            = it.line;
        decl.col             = it.col;
        decl.name_end        = it.name_end;
        decl.kind            = it.kind;
        decl.signature       = copy_string(it.signature);
        decl.module          = copy_string(module);
        decl.completion_base = copy_string(it.completion_base);
        array_add(*g_decls, decl);
        g_decls_generation += 1;
    }
    return true;
}

save_index_cache :: (path: string, module: string, modtime: Apollo_Time, size: s64, first_decl: s64) {
    cache_path := index_cache_path(path);
    if !cache_path { return; }

    count := g_decls.count - first_decl;
    if count < 0 || count > 0xffff_ffff { return; }

    builder: String_Builder;
    append(*builder, INDEX_CACHE_MAGIC);
    cache_append_value(*builder, INDEX_CACHE_VERSION);
    cache_append_string(*builder, path);
    cache_append_string(*builder, module);
    cache_append_value(*builder, size);
    cache_append_value(*builder, modtime.low);
    cache_append_value(*builder, modtime.high);
    cache_append_value(*builder, cast(u32) count);

    if count > 0 {
        for i: first_decl..g_decls.count-1 {
            decl := g_decls[i];
            cache_append_value(*builder, cast(u8) decl.kind);
            cache_append_value(*builder, decl.line);
            cache_append_value(*builder, decl.col);
            cache_append_value(*builder, decl.name_end);
            cache_append_string(*builder, decl.name);
            cache_append_string(*builder, decl.signature);
            cache_append_string(*builder, decl.completion_base);
        }
    }
    write_entire_file(cache_path, *builder);
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
