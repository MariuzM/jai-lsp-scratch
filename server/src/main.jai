#import "Basic";
#import "String";
#import "File";
#import "File_Utilities";
#import "Jai_Lexer";
#import "Hash_Table";
#import "Process";
Posix :: #import "POSIX";
#load "lsp/rpc.jai";
#load "lsp/json.jai";
#load "lsp/handlers.jai";
#load "lang/workspace.jai";
#load "lang/index.jai";
#load "lang/check.jai";
#load "lang/format.jai";
#load "lang/format_split.jai";
#load "lang/format_align.jai";
#load "lang/format_html.jai";

g_heap: Allocator;
g_root: string;

g_compiler := "jai";
g_shutdown := false;
g_exit     := false;

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
