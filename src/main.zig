const std = @import("std");
const Kira = @import("Kira");

pub fn main() !void {
    const stdout_file = std.fs.File.stdout();
    const stdin_file = std.fs.File.stdin();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try stdout_file.writeAll("Kira Programming Language v0.1.0\n");
    try stdout_file.writeAll("Type :help for help, :quit to exit\n\n");

    var line_buf: [4096]u8 = undefined;
    var line_len: usize = 0;

    while (true) {
        try stdout_file.writeAll("kira> ");

        // Read one character at a time until newline
        line_len = 0;
        while (line_len < line_buf.len) {
            const bytes_read = stdin_file.read(line_buf[line_len..][0..1]) catch |err| {
                if (err == error.EndOfStream or err == error.BrokenPipe) {
                    try stdout_file.writeAll("\nGoodbye!\n");
                    return;
                }
                return err;
            };
            if (bytes_read == 0) {
                try stdout_file.writeAll("\nGoodbye!\n");
                return;
            }
            if (line_buf[line_len] == '\n') break;
            line_len += 1;
        }

        const line = line_buf[0..line_len];
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, ":")) {
            if (std.mem.eql(u8, trimmed, ":quit") or std.mem.eql(u8, trimmed, ":q")) {
                try stdout_file.writeAll("Goodbye!\n");
                break;
            } else if (std.mem.eql(u8, trimmed, ":help") or std.mem.eql(u8, trimmed, ":h")) {
                try printHelp(stdout_file);
            } else if (std.mem.eql(u8, trimmed, ":tokens")) {
                try stdout_file.writeAll("Token mode enabled. Enter an expression to see its tokens.\n");
            } else {
                try stdout_file.writeAll("Unknown command. Type :help for available commands.\n");
            }
            continue;
        }

        // Tokenize the input
        var tokens = Kira.tokenize(allocator, trimmed) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Lexer error: {}\n", .{err}) catch "Lexer error\n";
            try stdout_file.writeAll(msg);
            continue;
        };
        defer tokens.deinit(allocator);

        // Print tokens for now (until parser is implemented)
        try stdout_file.writeAll("Tokens:\n");
        var print_buf: [512]u8 = undefined;
        for (tokens.items) |tok| {
            const line_out = std.fmt.bufPrint(&print_buf, "  {s}: \"{s}\" at {d}:{d}\n", .{
                @tagName(tok.type),
                tok.lexeme,
                tok.span.start.line,
                tok.span.start.column,
            }) catch continue;
            try stdout_file.writeAll(line_out);
        }
    }
}

fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Commands:
        \\  :help, :h    Show this help message
        \\  :quit, :q    Exit the REPL
        \\  :tokens      Show token stream for input
        \\  :type <expr> Show the type of an expression (not yet implemented)
        \\  :load <file> Load a .ki file (not yet implemented)
        \\
        \\Enter Kira expressions or statements to evaluate.
        \\
    );
}

test "Kira tokenize works" {
    var tokens = try Kira.tokenize(std.testing.allocator, "let x = 1");
    defer tokens.deinit(std.testing.allocator);
    try std.testing.expect(tokens.items.len > 0);
}
