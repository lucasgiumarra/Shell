//! StreamReader will read keyboard inputs from stdin in raw mode
//! so that autocomplete can be achieved

const StreamReader = @This();

const std = @import("std");
const builtin = @import("builtin");
const io = std.io;
const os = std.os;
const posix = std.posix;
const mem = std.mem;
// const stdin = std.io.getStdIn();
// const stdout = std.io.getStdOut();
const Allocator = std.mem.Allocator;
const completions = [_][]const u8{ "echo ", "exit ", "type " };
const to_be_completed = [_][]const u8{ "ech", "exi", "typ" };

input_buffer: std.ArrayList(u8),
stdin: std.fs.File,
stdout: std.fs.File,
list_of_commands: std.ArrayList([]const u8),
allocator: Allocator,
last_was_tab: bool,
has_similar_name: bool,
pub fn init(reader: std.fs.File, writer: std.fs.File, alloc: Allocator) StreamReader {
    return StreamReader{
        .stdin = reader,
        .stdout = writer,
        .input_buffer = std.ArrayList(u8).init(alloc),
        .list_of_commands = std.ArrayList([]const u8).init(alloc),
        .allocator = alloc,
        .last_was_tab = false,
        .has_similar_name = false,
    };
}

pub fn stream(self: *StreamReader) !void {
    // Enable raw mode
    try self.enableRawMode();
    defer self.disableRawMode() catch {};
    const alloc = self.allocator;
    defer self.input_buffer.deinit();

    while (true) {
        // Read a single character
        var buf: [1]u8 = undefined;
        const bytes_read = try self.stdin.read(&buf);
        if (bytes_read == 0) break;

        const char = buf[0];

        // Handle special keys
        switch (char) {
            // Ctrl-C to exit
            3 => break,

            // Tab for autocomplete
            '\t' => {
                // Find the best completion
                var best_completion: ?[]const u8 = null;
                for (to_be_completed, 0..) |complete, ind| {
                    if (std.mem.eql(u8, complete, self.input_buffer.items)) {
                        best_completion = completions[ind];
                        break;
                    }
                }

                const path_completion = try self.autofillPathExe(self.input_buffer.items);

                // If we found a completion
                if (best_completion) |completion| {
                    // Clear current input
                    try self.stdout.writeAll("\r");
                    try clearLine(self.stdout.writer());

                    // Write the full completion
                    try self.stdout.writer().print("$ ", .{});
                    try self.stdout.writer().writeAll(completion);

                    // Reset input buffer
                    self.input_buffer.clearAndFree();
                    try self.input_buffer.appendSlice(completion);
                } else if (path_completion) |completion| {
                    // Clear current input
                    try self.stdout.writeAll("\r");
                    try clearLine(self.stdout.writer());
                    // std.debug.print("{s}\n", .{completion});

                    // Write the full completion
                    if (self.last_was_tab) {
                        // std.debug.print("2nd tab\n", .{});
                        // try self.stdout.writer().print("$ ", .{});
                        // try self.stdout.writer().print("\n", .{});
                        try self.stdout.writer().print("$ {s}\n", .{self.input_buffer.items});
                        try self.stdout.writer().writeAll(completion);
                        // try self.stdout.writer().print("\n", .{});
                        // const str = try alloc.dupe(u8, self.input_buffer.items);
                        // try self.list_of_commands.append(str);
                        // break;
                        try self.stdout.writer().print("\n$ {s}", .{self.input_buffer.items});
                        self.last_was_tab = false;
                        continue;
                    } else if (self.has_similar_name) {
                        try self.stdout.writer().print("$ ", .{});
                        self.input_buffer.clearAndFree();
                        try self.input_buffer.appendSlice(completion);
                        // try self.stdout.writer().writeAll(completion);
                        try self.stdout.writer().writeAll(self.input_buffer.items);
                        self.has_similar_name = false;
                        continue;
                    } else {
                        // std.debug.print("1st tab\n", .{});
                        try self.stdout.writer().print("$ ", .{});
                        try self.stdout.writer().writeAll(completion);
                        try self.stdout.writer().print(" ", .{});
                        self.last_was_tab = true;
                        continue;
                        // try self.stdout.writer().print(" ", .{});
                    }

                    // Reset input buffer
                    self.input_buffer.clearAndFree();
                    try self.input_buffer.appendSlice(completion);
                } else {
                    // Send the bell character to signal an invalid completion attempt
                    try self.stdout.writeAll("\x07");
                }
                self.last_was_tab = true;
            },

            // Backspace
            127 => {
                if (self.input_buffer.items.len > 0) {
                    _ = self.input_buffer.pop();
                    try self.stdout.writeAll("\r");
                    try clearLine(self.stdout.writer());
                    try self.stdout.writer().print("$ ", .{});
                    try self.stdout.writer().writeAll(self.input_buffer.items);
                }
                self.last_was_tab = false;
            },

            // Newline
            '\r', '\n' => {
                try self.stdout.writer().writeAll("\n");
                const str = try alloc.dupe(u8, self.input_buffer.items);
                try self.list_of_commands.append(str);
                self.input_buffer.clearAndFree();
                self.last_was_tab = false;
                break;
            },
            32...126 => {
                try self.input_buffer.append(char);
                try self.stdout.writer().writeAll(&[_]u8{char});
                self.last_was_tab = false;
            },

            // Regular characters
            else => {
                self.last_was_tab = false;
                continue;
            },
        }
    }
}

fn autofillPathExe(self: *StreamReader, user_input: []const u8) !?[]const u8 {
    var env_var = try std.process.getEnvMap(self.allocator);
    defer env_var.deinit();
    const path_env = env_var.get("PATH") orelse return null;
    var paths = mem.splitAny(u8, path_env, ":");
    var executables = std.ArrayList([]const u8).init(self.allocator);
    while (paths.next()) |path| {
        // std.debug.print("{s}\n", .{path});
        const directory_path = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch {
            continue;
        };

        var dir_iterator = directory_path.iterate();
        while (true) {
            const file_optional = dir_iterator.next() catch |err| {
                std.debug.print("Error reading directory: {}\n", .{err});
                break;
            };
            if (file_optional == null) break;
            const file = file_optional.?;
            // var has_similar_name = false;
            if (mem.startsWith(u8, file.name, user_input)) {
                const file_name = try self.allocator.dupe(u8, file.name);
                // std.debug.print("\nfile: {s}\n", .{file.name});
                for (executables.items, 0..) |exe, ind| {
                    // Does the current file have the same name as a file that already exists in executables
                    // i.e. foo_bar and foo_bar_baz
                    if (mem.startsWith(u8, exe, file.name)) {
                        // std.debug.print("\nfile.name:{s}\n", .{file.name});
                        executables.items[ind] = file_name;
                        self.has_similar_name = true;
                    } else if (mem.startsWith(u8, file.name, exe)) {
                        std.debug.print("\nexe: {s}\n", .{exe});
                        self.has_similar_name = true;
                    }
                }
                if (self.has_similar_name) {
                    continue;
                }
                // std.debug.print("\n{s}\n", .{file.name});

                try executables.append(file_name);
            }
        }
    }
    if (executables.items.len == 1) {
        const duped_val = try self.allocator.dupe(u8, executables.items[0]);
        return duped_val;
    } else if (executables.items.len > 1) {
        std.mem.sort([]const u8, executables.items, {}, compareExecutables);
        if (self.last_was_tab) {
            const joined = try std.mem.join(self.allocator, "  ", executables.items);
            // std.debug.print("{s}\n", .{joined});
            return joined;
        }
        return try std.mem.join(self.allocator, "", &[_][]const u8{ user_input, "\x07" });
    }
    return null;
}

fn compareExecutables(ctx: void, a: []const u8, b: []const u8) bool {
    _ = ctx; // Unused
    return std.mem.lessThan(u8, a, b);
}

pub fn closeStream(self: *StreamReader) !void {
    self.input_buffer.deinit();
    self.stdin.close();
    self.stdout.close();
    for (self.list_of_commands.items) |str| {
        self.allocator.free(str);
    }
    self.list_of_commands.deinit();
    // try self.disableRawMode();
}

pub fn getWritten(self: *StreamReader) !?[]const u8 {
    const last_index = self.list_of_commands.items.len - 1;
    if (last_index >= 0) {
        return self.list_of_commands.items[last_index];
    } else {
        return null;
    }
}

// Clear the current line
fn clearLine(writer: anytype) !void {
    try writer.writeAll("\x1b[K");
}

// Enable raw mode for terminal input
// fd: posix.fd_t
fn enableRawMode(self: StreamReader) !void {
    const fd = self.stdin.handle;
    const termios = try posix.tcgetattr(fd);
    var raw = termios;

    // Disable canonical mode and echo
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false; // Disable signal generation

    try posix.tcsetattr(fd, .FLUSH, raw);
}

// Restore terminal to normal mode
fn disableRawMode(self: StreamReader) !void {
    const fd = self.stdin.handle;
    const termios = try posix.tcgetattr(fd);
    var original = termios;

    original.lflag.ICANON = true;
    original.lflag.ECHO = true;
    original.lflag.ISIG = true;

    try posix.tcsetattr(fd, .FLUSH, original);
}
