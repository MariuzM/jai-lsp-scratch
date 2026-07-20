platform_read_stdin :: (data: *u8, count: s64) -> s64 {
    #if OS == .WINDOWS {
        handle := Windows.GetStdHandle(Windows.STD_INPUT_HANDLE);
        bytes_read: u32;
        success := Windows.ReadFile(handle, data, cast(u32) count, *bytes_read, null);
        return ifx success then cast(s64) bytes_read else -1;
    } else {
        return Posix.read(Posix.STDIN_FILENO, data, cast(u64) count);
    }
}

platform_temporary_directory :: () -> string {
    #if OS == .WINDOWS {
        required := GetTempPathW(0, null);
        if !required { return ""; }

        buffer := cast(*u16) talloc(cast(s64) required * size_of(u16));
        count  := GetTempPathW(required, buffer);
        if !count || count >= required { return ""; }

        result := Windows_Utf8.wide_to_utf8(buffer, length = cast(s32) count,, allocator = temp);
        path_overwrite_separators(result, #char "/");
        while result.count > 1 && result[result.count - 1] == #char "/" result.count -= 1;
        return result;
    } else {
        value := Posix.getenv("TMPDIR".data);
        if value { return to_string(value); }
        return "/tmp";
    }
}

platform_resolve_executable :: (path: string) -> string {
    has_forward_slash, _ := contains(path, #char "/");
    has_back_slash, _    := contains(path, #char "\\");

    if has_forward_slash || has_back_slash {
        if !file_exists(path) { return path; }
        absolute, success := get_absolute_path(path);
        if success {
            #if OS == .WINDOWS path_overwrite_separators(absolute, #char "/");
            return absolute;
        }
        return path;
    }

    #if OS == .WINDOWS {
        path_wide      := Windows_Utf8.utf8_to_wide(path,, allocator = temp);
        extension_wide := Windows_Utf8.utf8_to_wide(".exe",, allocator = temp);
        required       := SearchPathW(null, path_wide, extension_wide, 0, null, null);
        if !required { return path; }

        buffer := cast(*u16) talloc(cast(s64)(required + 1) * size_of(u16));
        count  := SearchPathW(null, path_wide, extension_wide, required + 1, buffer, null);
        if !count || count > required { return path; }

        result := Windows_Utf8.wide_to_utf8(buffer, length = cast(s32) count,, allocator = temp);
        path_overwrite_separators(result, #char "/");
        return result;
    } else {
        value := Posix.getenv("PATH".data);
        if !value { return path; }

        remaining := to_string(value);
        while remaining.count > 0 {
            found, directory, rest := split_from_left(remaining, ":");
            if found { remaining = rest; }
            else     { directory = remaining; remaining = ""; }
            if !directory { continue; }

            candidate := tprint("%/%", directory, path);
            if !file_exists(candidate) { continue; }

            absolute, success := get_absolute_path(candidate);
            if success { return absolute; }
            return candidate;
        }
        return path;
    }
}

#scope_file

#if OS == .WINDOWS {
    kernel32     :: #system_library "kernel32";
    GetTempPathW :: (buffer_length: u32, buffer: *u16) -> u32                                                                 #foreign kernel32;
    SearchPathW  :: (path: *u16, file_name: *u16, extension: *u16, buffer_length: u32, buffer: *u16, file_part: **u16) -> u32 #foreign kernel32;
}
