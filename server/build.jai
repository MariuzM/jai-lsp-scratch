#import "Compiler";
#import "Basic";
#import "String";
#import "File";
#import "File_Utilities";
#import "Process";

#run build();

Build_Target :: enum {
    BUILD;
    BUNDLE;
    CLEAN;
}

build :: () {
    set_build_options_dc(.{do_output = false});
    if !set_working_directory(#filepath) {
        log_error("Could not switch to the server directory.\n");
        compiler_set_workspace_status(.FAILED);
        return;
    }

    target, valid := parse_target(get_build_options().compile_time_command_line);
    if !valid {
        compiler_set_workspace_status(.FAILED);
        return;
    }

    if target == .CLEAN {
        if file_exists("build") && !delete_directory("build") {
            log_error("Could not remove the server build directory.\n");
            compiler_set_workspace_status(.FAILED);
        }
        for file_list("../extension") {
            if ends_with(it, ".vsix") && !file_delete(it) {
                log_error("Could not remove %.\n", it);
                compiler_set_workspace_status(.FAILED);
            }
        }
        return;
    }

    if !compile_server(optimized = target == .BUNDLE) {
        compiler_set_workspace_status(.FAILED);
        return;
    }

    if target == .BUNDLE && !bundle_server() {
        compiler_set_workspace_status(.FAILED);
    }
}

parse_target :: (arguments: []string) -> Build_Target, bool {
    if arguments.count == 0 || arguments[0] == "build" return .BUILD, true;
    if arguments[0] == "bundle"                        return .BUNDLE, true;
    if arguments[0] == "clean"                         return .CLEAN, true;

    log_error("Unknown build target '%'. Expected build, bundle, or clean.\n", arguments[0]);
    return .BUILD, false;
}

compile_server :: (optimized: bool) -> bool {
    workspace := compiler_create_workspace("jai-lsp-scratch");
    if !workspace {
        log_error("Could not create the server build workspace.\n");
        return false;
    }

    options := get_build_options(workspace);
    options.output_executable_name = "jai-lsp-scratch";
    options.output_path            = "build";
    options.intermediate_path      = "build/.build";
    if optimized { set_optimization(*options, .OPTIMIZED); }
    #if OS == .MACOS { options.use_custom_link_command = true; }
    set_build_options(options, workspace);

    compiler_begin_intercept(workspace, .SKIP_ALL);
    add_build_file("src/main.jai", workspace);

    succeeded := false;
    linked    := true;
    while true {
        message := compiler_wait_for_message();
        if message.kind == .PHASE {
            phase := cast(*Message_Phase) message;
            if phase.phase == .READY_FOR_CUSTOM_LINK_COMMAND {
                linked = link_with_clang(phase, tprint("%/%", options.output_path, options.output_executable_name));
                compiler_custom_link_command_is_complete(workspace);
            }
            continue;
        }
        if message.kind != .COMPLETE { continue; }

        complete := cast(*Message_Complete) message;
        succeeded = complete.error_code == .NONE && linked;
        break;
    }
    compiler_end_intercept(workspace);
    return succeeded;
}

link_with_clang :: (phase: *Message_Phase, output: string) -> bool {
    command: [..]string;
    array_add(*command, "clang", "-arch", ifx CPU == .ARM64 then "arm64" else "x86_64");
    array_add(*command, "-mmacosx-version-min=11.0", "-Wl,-rpath,@loader_path", "-o", output);
    for phase.compiler_generated_object_files array_add(*command, it);
    for phase.support_object_files            array_add(*command, it);
    for phase.system_libraries                array_add(*command, it);
    for phase.user_libraries                  array_add(*command, it);

    result := run_command(..command);
    if result.exit_code != 0 {
        log_error("Linking with clang failed.\n");
        return false;
    }
    return true;
}

bundle_server :: () -> bool {
    #if OS == .WINDOWS && CPU == .X64 {
        source      := "build/jai-lsp-scratch.exe";
        destination := "../extension/bin/jai-lsp-scratch-windows-x64.exe";
    } else #if OS == .MACOS && CPU == .ARM64 {
        source      := "build/jai-lsp-scratch";
        destination := "../extension/bin/jai-lsp-scratch-darwin-arm64";
    } else #if OS == .MACOS && CPU == .X64 {
        source      := "build/jai-lsp-scratch";
        destination := "../extension/bin/jai-lsp-scratch-darwin-x64";
    } else #if OS == .LINUX && CPU == .ARM64 {
        source      := "build/jai-lsp-scratch";
        destination := "../extension/bin/jai-lsp-scratch-linux-arm64";
    } else #if OS == .LINUX && CPU == .X64 {
        source      := "build/jai-lsp-scratch";
        destination := "../extension/bin/jai-lsp-scratch-linux-x64";
    } else {
        log_error("Bundling is not configured for this platform.\n");
        return false;
    }

    if !make_directory_if_it_does_not_exist("../extension/bin", recursive = true) return false;
    if !copy_file(source, destination)                                            return false;

    source_data, source_ok           := read_entire_file(source);
    destination_data, destination_ok := read_entire_file(destination);
    defer if source_ok free(source_data);
    defer if destination_ok free(destination_data);

    if !source_ok || !destination_ok || source_data != destination_data {
        log_error("Bundled executable did not match the compiler output.\n");
        return false;
    }

    print("Bundled %\n", destination);
    return true;
}
