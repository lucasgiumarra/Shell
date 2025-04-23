const StreamReader = @This();


const std = @import("std");
const builtin = @import("builtin");
const io = std.io;
const os = std.os;
const posix = std.posix;
const mem = std.mem;

    const stdin = std.io.getStdIn();
    const stdout = std.io.getStdOut();

    // Predefined completions
    const completions = [_][]const u8{ "echo", "exit", "help", "hello" };

    // Enable raw mode
    try enableRawMode(stdin.handle);
    defer disableRawMode(stdin.handle) catch {};

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var input_buffer = std.ArrayList(u8).init(allocator);
    defer input_buffer.deinit();

    while (true) {
        // Read a single character
        var buf: [1]u8 = undefined;
        const bytes_read = try stdin.read(&buf);
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
                for (completions) |completion| {
                    if (std.mem.startsWith(u8, completion, input_buffer.items)) {
                        best_completion = completion;
                        break;
                    }
                }

                // If we found a completion
                if (best_completion) |completion| {
                    // Clear current input
                    try stdout.writeAll("\r");
                    try clearLine(stdout.writer());

                    // Write the full completion
                    try stdout.writer().writeAll(completion);

                    // Reset input buffer
                    input_buffer.clearAndFree();
                    try input_buffer.appendSlice(completion);
                }
            },

            // Backspace
            127 => {
                if (input_buffer.items.len > 0) {
                    _ = input_buffer.pop();
                    try stdout.writeAll("\r");
                    try clearLine(stdout.writer());
                    try stdout.writer().writeAll(input_buffer.items);
                }
            },

            // Newline
            '\r', '\n' => {
                try stdout.writer().writeAll("\n");

                // Process the input
                if (mem.eql(u8, input_buffer.items, "exit 0")) break;

                // Clear buffer
                input_buffer.clearAndFree();
            },

            // Regular characters
            else => {
                try input_buffer.append(char);
                try stdout.writer().writeAll(&[_]u8{char});
            },
        }
    }

// Clear the current line
fn clearLine(writer: anytype) !void {
    try writer.writeAll("\x1b[K");
}

// Enable raw mode for terminal input
fn enableRawMode(fd: posix.fd_t) !void {
    const termios = try posix.tcgetattr(fd);
    var raw = termios;

    // Disable canonical mode and echo
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;

    try posix.tcsetattr(fd, .FLUSH, raw);
}

// Restore terminal to normal mode
fn disableRawMode(fd: posix.fd_t) !void {
    const termios = try posix.tcgetattr(fd);
    var original = termios;

    original.lflag.ICANON = true;
    original.lflag.ECHO = true;

    try posix.tcsetattr(fd, .FLUSH, original);
}   
