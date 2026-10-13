#import "Basic";
#import "String";
#import "File";
#import "File_Utilities";
#import "Jai_Lexer";
#import "Hash_Table";
#import "Process";
#load "platform.jai";
#load "lsp/rpc.jai";
#load "lsp/json.jai";
#load "lsp/handlers.jai";
#load "lang/workspace.jai";
#load "lang/index.jai";
#load "lang/cache.jai";
#load "lang/complete.jai";
#load "lang/check.jai";
#load "lang/format.jai";
#load "lang/format_split.jai";
#load "lang/format_align.jai";
#load "lang/format_html.jai";
#load "lang/format_wrap.jai";

#if OS == .WINDOWS {
    Windows      :: #import "Windows";
    Windows_Utf8 :: #import "Windows_Utf8";

} else {
    Posix :: #import "POSIX";

}

g_heap: Allocator;
g_root: string;

g_compiler := "jai";
g_shutdown := false;
g_exit     := false;

g_space_after_array_type := true;

main :: () {
    g_heap         = context.allocator;
    context.logger = stderr_logger;

    format_only := false;
    for get_command_line_arguments() {
        if it == "--format"                    { format_only = true; }
        if it == "--no-space-after-array-type" { g_space_after_array_type = false; }
    }
    if format_only {
        format_stdin();
        return;
    }

    log_err("jai-lsp-scratch starting");

    while !g_exit {
        body, ok := read_message();
        if !ok { break; }
        handle_message(body);
        {
            push_allocator(g_heap);
            free(body);
        }
        reset_temporary_storage();
    }
    log_err("jai-lsp-scratch exiting");
}

format_stdin :: () {
    builder: String_Builder;
    buffer: [65536]u8;
    while true {
        count := platform_read_stdin(buffer.data, buffer.count);
        if count < 0 {
            log_err("could not read stdin");
            exit(1);
        }
        if count == 0 { break; }
        append(*builder, buffer.data, count);
    }
    write_string(format_source(builder_to_string(*builder)));
}

stderr_logger :: (message: string, data: *void, info: Log_Info) {
    if !message.count return;
    write_all(2, message);
    if message[message.count - 1] != #char "\n" { write_all(2, "\n"); }
}
