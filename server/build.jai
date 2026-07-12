#import "Compiler";
#import "Basic";

#run {
    set_build_options_dc(.{do_output = false});

    w       := compiler_create_workspace("jai-lsp-scratch");
    options := get_build_options(w);
    options.output_executable_name = "jai-lsp-scratch";
    options.output_path            = "build";
    options.intermediate_path      = "build/.build";
    set_build_options(options, w);
    add_build_file("src/main.jai", w);
}
