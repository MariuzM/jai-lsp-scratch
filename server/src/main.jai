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

stderr_logger :: (message: string, data: *void, info: Log_Info) {
    if !message.count return;
    write_all(2, message);
    if message[message.count - 1] != #char "\n" { write_all(2, "\n"); }
}
