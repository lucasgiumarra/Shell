const std = @import("std");
const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();
const stdin = std.io.getStdIn().reader();
const Child = std.process.Child;
const GPA = std.heap.GeneralPurposeAllocator(.{}){};
const mem = std.mem;
const testing = std.testing;
const stream_reader = @import("StreamReader.zig");

const FileStream = struct {
    stdout: std.fs.File.Writer,
    stderr: std.fs.File.Writer,
    pub fn init(out: std.fs.File.Writer, err: std.fs.File.Writer) FileStream {
        return FileStream{
            .stdout = out,
            .stderr = err,
        };
    }
};

fn echo(user_input: []const u8, writer: FileStream) !bool {
    if (user_input.len < 4 or !mem.eql(u8, user_input[0..4], "echo")) return false;
    const arg = std.mem.trimLeft(u8, user_input[4..], " \t");
    try writer.stdout.writeAll(arg);
    try writer.stdout.print("\n", .{});
    return true;
}

fn processQuoted(arg: []const u8, char_list: *std.ArrayList(u8), ind: *usize, last_val: *u8) !void {
    const sym = arg[ind.*];
    const quote_start = ind.* + 1;
    const quote_end = indexOfNextQuote(arg[quote_start..], sym) orelse {
        ind.* += 1;
        return;
    };
    if (sym == '\'' and ind.* != arg.len - 1) {
        for (arg[ind.* + 1 .. ind.* + quote_end + 1]) |char| {
            try char_list.*.append(char);
        }
    } else if (sym == '\"' and ind.* != arg.len - 1) {
        var i = ind.* + 1;
        while (i < ind.* + quote_end + 1) : (i += 1) {
            const char = arg[i];
            if (char == '\\' and i < ind.* + quote_end + 1) {
                const next_char = arg[i + 1];
                if (next_char == '\\' or next_char == '$' or next_char == '\"' or next_char == '\n') {
                    try char_list.*.append(next_char);
                    i += 1;
                    continue;
                }
            }
            try char_list.*.append(char);
        }
    }
    last_val.* = arg[ind.* + quote_end];
    ind.* = ind.* + 1 + quote_end + 1;
    return;
}

fn processUserInputQuotes(user_input: []const u8, allocator: mem.Allocator) ![]const u8 {
    if (user_input.len < 5 or mem.eql(u8, user_input[0..3], "cat")) return allocator.dupe(u8, user_input);
    var char_list = std.ArrayList(u8).init(allocator);
    errdefer char_list.deinit();
    if (mem.eql(u8, user_input[0..5], "\"cat\"")) {
        const user_input_trimmed = mem.trimLeft(u8, user_input[5..], " \t");
        try char_list.appendSlice("cat ");
        for (user_input_trimmed) |char| {
            try char_list.append(char);
        }
        return char_list.toOwnedSlice();
    }
    var ind: usize = 0;
    var last_val: u8 = undefined;
    while (ind < user_input.len) {
        const sym = user_input[ind];
        // std.debug.print("{c}\n", .{sym});

        if (sym == '\\') {
            if (ind < user_input.len - 1) {
                // char_list.append(user_input[ind + 1]) catch break;
                try char_list.append(user_input[ind + 1]);
                last_val = user_input[ind + 1];
                ind += 2;
                continue;
            } else {
                break;
            }
        } else if (sym == '\'' or sym == '\"') {
            try processQuoted(user_input, &char_list, &ind, &last_val); // ind is updated in the function
            continue;
        } else if (last_val == ' ' and sym == ' ') {
            ind += 1;
            continue;
        }
        try char_list.append(sym);
        last_val = sym;
        ind += 1;
    }

    const return_val = try char_list.toOwnedSlice();
    return return_val;
}

fn indexOfNextQuote(haystack: []const u8, needle: u8) ?usize {
    var index: ?usize = null;
    for (haystack, 0..) |hayval, ind| {
        // std.debug.print("\nhayval = {c}\n", .{hayval});
        if (hayval == needle) {
            if (ind > 1 and haystack[ind - 1] == '\\' and haystack[ind - 2] == '\\') {
                index = ind;
                break;
            } else if (ind > 0 and haystack[ind - 1] == '\\') {
                continue;
            }
            index = ind;
            break;
        }
    }
    return index;
}

fn exit(user_input: []const u8) !void {
    if (mem.eql(u8, user_input, "exit 0")) {
        try std.process.exit(0);
    }
}

fn isBuiltin(builtin: ?[]const u8) bool {
    const builtins = [_][]const u8{ "echo", "exit", "type", "pwd", "cd" };
    if (builtin) |b| {
        for (builtins) |bi| {
            if (mem.eql(u8, b, bi)) return true;
        }
    }
    return false;
}

fn runExternalProgram(token: mem.TokenIterator(u8, mem.DelimiterType.any), allocator: mem.Allocator, writer: FileStream) !bool {
    var tokens = token;
    const exe_file = tokens.next() orelse return false;
    var env_var = try std.process.getEnvMap(allocator);
    defer env_var.deinit();
    const path_env = env_var.get("PATH") orelse "";
    var paths = mem.splitAny(u8, path_env, ":");

    while (paths.next()) |path| {
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ path, exe_file });
        defer allocator.free(full_path);
        const file = std.fs.openFileAbsolute(full_path, .{ .mode = .read_only }) catch {
            continue;
        };
        defer file.close();
        const mode = file.mode() catch {
            continue;
        };
        const is_executable = mode & 0b001 != 0;
        if (!is_executable) {
            continue;
        }
        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();

        try args.append(exe_file);
        while (tokens.next()) |arg| {
            try args.append(arg);
        }
        var child = Child.init(args.items, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        // Read from the child's stdout and write to our stdout
        try pipeOutputToStd(child.stdout, writer.stdout);
        try pipeOutputToStd(child.stderr, writer.stderr);
        _ = try child.wait();
        return true;
    }
    return false;
}

fn pipeOutputToStd(out: ?std.fs.File, writer: std.fs.File.Writer) !void {
    if (out) |pipe| {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const bytes_read = try pipe.read(&buffer);
            if (bytes_read == 0) break;
            _ = try writer.write(buffer[0..bytes_read]); // Redirect stderr to stdout
        }
    }
}

fn typeCmd(tkn: mem.TokenIterator(u8, mem.DelimiterType.any), allocator: mem.Allocator, writer: FileStream) !bool {
    var token = tkn;
    const cmd = token.next() orelse return false;
    if (!mem.eql(u8, cmd, "type")) return false;
    const argument = token.next();
    if (argument) |arg| {
        if (isBuiltin(arg)) {
            try writer.stdout.print("{s} is a shell builtin\n", .{arg});
        } else {
            var env_var = try std.process.getEnvMap(allocator);
            defer env_var.deinit();
            const path_env = env_var.get("PATH") orelse "";
            var paths = mem.splitAny(u8, path_env, ":");

            while (paths.next()) |path| {
                const fullPath = try std.fs.path.join(allocator, &[_][]const u8{ path, arg });
                defer allocator.free(fullPath);
                const file = std.fs.openFileAbsolute(fullPath, .{ .mode = .read_only }) catch {
                    continue;
                };
                defer file.close();
                const mode = file.mode() catch {
                    continue;
                };
                const is_executable = mode & 0b001 != 0;
                if (!is_executable) {
                    continue;
                }
                try writer.stdout.print("{s} is {s}\n", .{ arg, fullPath });
                return true;
            }
            try writer.stdout.print("{s}: not found\n", .{arg});
        }
    } else {
        try writer.stdout.print("\n", .{});
    }
    return true;
}

fn printWorkingDir(user_input: []const u8, writer: FileStream) !bool {
    if (mem.eql(u8, user_input[0..], "pwd")) {
        // From ziglang.org as of 2/17/2025:
        // max_path_bytes - The maximum length of a file path that the operating system will accept.
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fs.cwd().realpath(".", &buffer);
        try writer.stdout.print("{s}\n", .{path});
        return true;
    }
    return false;
}

fn formatCatTokens(input: []const u8, allocator: mem.Allocator, tokens: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i < input.len) {
        // Skip whitespace.
        while (i < input.len and std.ascii.isWhitespace(input[i])) : (i += 1) {}
        if (i >= input.len) break;
        const start = i;
        if (input[i] == '\'') {
            i += 1; // Skip opening quote.
            while (i < input.len and input[i] != '\'') : (i += 1) {}
            if (i >= input.len) {
                return error.MissingClosingQuote;
            }
            const slice = input[start + 1 .. i]; // Append the token without the quotes.
            const duped_slice = try allocator.dupe(u8, slice); // Duplicate the slice to manage its memory so that the memory is not shared with const slice
            try tokens.*.append(duped_slice);
            i += 1; // Skip closing quote.
        } else if (input[i] == '\"') {
            i += 1; // Skip opening quote.
            var tokenBuilder = std.ArrayList(u8).init(allocator);
            errdefer tokenBuilder.deinit(); // .deinit() is not needed since .toOwnedSlice is called, but it is still safe
            while (i < input.len and input[i] != '\"') : (i += 1) {
                const char = input[i];
                if (char == '\\' and i + 1 < input.len) {
                    const next_char = input[i + 1];
                    if (next_char == '\\' or next_char == '$' or next_char == '"' or next_char == '\n') {
                        continue;
                    }
                }
                try tokenBuilder.append(char);
            }
            const owned_slice = try tokenBuilder.toOwnedSlice();
            try tokens.*.append(owned_slice);
            i += 1; // Skip closing quote.
        } else {
            // Token is not quoted: read until next whitespace.
            while (i < input.len and !std.ascii.isWhitespace(input[i])) : (i += 1) {}
            const slice = input[start..i];
            const duped_slice = try allocator.dupe(u8, slice);
            try tokens.*.append(duped_slice);
        }
    }
}

/// Parses a command-line input (without the command itself) into tokens,
/// handling single-quoted tokens.
fn parseCatTokens(input: []const u8, allocator: mem.Allocator) ![]const []const u8 {
    var tokens = std.ArrayList([]const u8).init(allocator);
    errdefer { // ensures cleanup if errors occur
        for (tokens.items) |token| {
            allocator.free(token);
        }
        tokens.deinit();
    }
    formatCatTokens(input, allocator, &tokens) catch return error.FailedToFormat;
    return tokens.toOwnedSlice();
}

pub fn processCat(user_input: []const u8, allocator: mem.Allocator, writer: FileStream) !bool {
    if (user_input.len < 3 or !mem.eql(u8, user_input[0..3], "cat")) return false;
    const args = user_input[3..];
    const args_part = mem.trimLeft(u8, args, " \t");
    const tokens = parseCatTokens(args_part, allocator) catch {
        std.debug.print("cat failed to run", .{});
        return true;
    };
    defer {
        for (tokens) |token| allocator.free(token); // The tokens have their own allocated memory so must be freed
        allocator.free(tokens); // tokens constant must be freed as well since parseTokens() is returning a .toOwnedSlice() which returns the memory to the caller
    }
    var args_list = std.ArrayList([]const u8).init(allocator);
    defer args_list.deinit();
    try args_list.append("cat");
    for (tokens) |token| {
        try args_list.append(token);
    }
    // try printCat(args_list, allocator);
    var child = Child.init(args_list.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    // Read from the child's stdout and write to our stdout
    try pipeOutputToStd(child.stdout, writer.stdout);
    try pipeOutputToStd(child.stderr, writer.stderr);

    _ = try child.wait();

    return true;
}

fn findExecutable(exec: []const u8, allocator: mem.Allocator) !?[]const u8 {
    // const allocator = std.heap.page_allocator;

    // Retrieve the PATH environment variable.
    var env_path = try std.process.getEnvMap(allocator);
    defer env_path.deinit();
    const maybe_path = env_path.get("PATH") orelse "";
    // if (maybePath) return null;
    const pathStr = maybe_path;

    // Split the PATH string into its constituent directories.
    var parts = std.mem.splitAny(u8, pathStr, ":");

    // Iterate over each directory in PATH.
    while (parts.next()) |dir| {
        // Build the candidate full path (e.g., "/bin/cat")
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, exec });
        // Store the result of statFile with a catch to return null on error.
        const candidateStat = std.fs.cwd().statFile(candidate) catch null;
        if (candidateStat != null) {
            return candidate;
        }
        allocator.free(candidate);
    }
    return null;
}

fn runIfExecutable(user_input: []const u8, alloc: mem.Allocator, writer: FileStream) !bool {
    var it = std.mem.splitAny(u8, user_input, "/");
    const token = it.next() orelse "";
    const exec_name = std.mem.trimRight(u8, token, " \t");
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const allocator = arena.allocator();
    const exe = try findExecutable(exec_name, allocator);
    if (exe) |path| {
        allocator.free(path);
    } else {
        return false;
    }
    var args_list = std.ArrayList([]const u8).init(allocator);
    try args_list.append(exec_name);
    const str = try std.mem.concat(allocator, u8, &[_][]const u8{ "/", it.rest() });
    defer allocator.free(str);
    try args_list.append(str);
    var child = Child.init(args_list.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    // Read from the child's stdout and write to our stdout
    try pipeOutputToStd(child.stdout, writer.stdout);
    try pipeOutputToStd(child.stderr, writer.stderr);

    _ = try child.wait();

    return true;
}

fn changeDirectory(tkn: mem.TokenIterator(u8, mem.DelimiterType.any), allocator: mem.Allocator, writer: FileStream) !bool {
    var token = tkn;
    const cmd = token.next() orelse return false;
    if (!mem.eql(u8, cmd, "cd")) return false;
    const fullpath = token.peek() orelse return false;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    var path: []const u8 = undefined;

    if (mem.eql(u8, fullpath, "~")) {
        var env_var = try std.process.getEnvMap(allocator);
        defer env_var.deinit();
        const home_env = env_var.get("HOME") orelse "";
        path = std.fs.cwd().realpath(home_env, &buffer) catch {
            writer.stdout.print("{s}: No such file or directory\n", .{fullpath}) catch return true;
            return true;
        };
    } else {
        path = std.fs.cwd().realpath(fullpath, &buffer) catch {
            writer.stdout.print("{s}: No such file or directory\n", .{fullpath}) catch return true;
            return true;
        };
    }
    // Open the resolved directory and set as CWD
    var dir = try std.fs.openDirAbsolute(path, .{
        .access_sub_paths = true,
        .iterate = true,
        .no_follow = false,
    });
    defer dir.close();
    try std.fs.Dir.setAsCwd(dir);
    return true;
}

fn unknowCommand(user_input: []const u8, writer: FileStream) !void {
    try writer.stdout.print("{s}: command not found\n", .{user_input});
}

fn noCommand(user_input: []const u8, writer: anytype) !bool {
    if (mem.eql(u8, user_input[0..], "")) {
        try writer.stdout.print("", .{});
        return true;
    }
    return false;
}

fn checkForRedirect(user_input: []const u8, allocator: mem.Allocator) !bool {
    // List must be in this order for logic to be performed correctly since indexOf is being used
    const redirects = [_][]const u8{ "1>>", "2>>", ">>", "1>", "2>", ">" };
    var command: ?[]const u8 = null;
    var file_path: ?[]const u8 = null;
    var append_mode = false;
    var stderr_redirect = false;

    for (redirects) |redir| {
        if (mem.indexOf(u8, user_input, redir) != null) {
            var it = mem.splitSequence(u8, user_input, redir);
            command = it.next();
            file_path = it.next();
            append_mode = mem.indexOf(u8, redir, ">>") != null;
            stderr_redirect = mem.indexOf(u8, redir, "2") != null;
            break;
        }
    }

    if (command == null or file_path == null) return false;

    const token = mem.tokenizeAny(u8, command.?, " \n\t");
    const trimmed_file_path = mem.trim(u8, file_path.?, " \t\r\n");
    const dir_path = std.fs.path.dirname(trimmed_file_path) orelse return false;

    std.fs.cwd().makeDir(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            std.debug.print("{s}\n", .{dir_path});
            std.debug.print("{}\n", .{err});
            return true;
        }
    };

    var file = try std.fs.cwd().createFile(trimmed_file_path, .{ .truncate = !append_mode });
    if (append_mode) try file.seekFromEnd(0);

    defer {
        file.close();
    }

    var type_writer: FileStream = undefined;
    const writer = file.writer();
    if (stderr_redirect) {
        // stderr = file.writer();
        type_writer = FileStream.init(stdout, writer);
    } else {
        // stdout = file.writer();
        type_writer = FileStream.init(writer, stderr);
    }
    try runCommand(command.?, token, allocator, type_writer);
    return true;
}

fn runCommand(user_input: []const u8, token: mem.TokenIterator(u8, mem.DelimiterType.any), allocator: mem.Allocator, writer: FileStream) anyerror!void {

    // Handle exit early
    try exit(user_input);

    // Handle built-in commands first
    if (try noCommand(user_input, writer)) return;
    if (try typeCmd(token, allocator, writer)) return;
    if (try processCat(user_input, allocator, writer)) return;
    if (try echo(user_input, writer)) return;
    if (try printWorkingDir(user_input, writer)) return;
    if (try changeDirectory(token, allocator, writer)) return;

    // Try executing an external command
    if (try runIfExecutable(user_input, allocator, writer)) return;
    if (try runExternalProgram(token, allocator, writer)) return;

    // If none matched, handle unknown command
    try unknowCommand(user_input, writer);
}

pub fn main() !void {
    var gpa = GPA;
    const child_alloc = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) testing.expect(false) catch @panic("TEST FAILED");
    }
    var arena = std.heap.ArenaAllocator.init(child_alloc);
    defer arena.deinit();
    const allocator = arena.allocator();
    const type_writer = FileStream.init(stdout, stderr);
    var StreamReader = stream_reader.init(std.io.getStdIn(), std.io.getStdOut(), allocator);
    while (true) {
        try stdout.print("$ ", .{});
        try StreamReader.stream();
        const read_input = try StreamReader.getWritten() orelse continue;
        const input_trim_left = mem.trimLeft(u8, read_input, " \t");
        const input_trimmed_left_and_right = mem.trimRight(u8, input_trim_left, " \t");
        const user_input = try processUserInputQuotes(input_trimmed_left_and_right, allocator);
        defer {
            allocator.free(user_input);
        }
        // std.debug.print("{s}\n", .{user_input});
        const token = mem.tokenizeAny(u8, user_input, " \t\n");
        if (try checkForRedirect(user_input, allocator)) continue;

        try runCommand(user_input, token, allocator, type_writer);
    }
}
