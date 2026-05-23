const std = @import("std");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn eql(self: Color, other: Color) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b;
    }
};

pub const Style = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    reversed: bool = false,

    pub fn eql(self: Style, other: Style) bool {
        const fg_eq = if (self.fg == null and other.fg == null) true else if (self.fg != null and other.fg != null) self.fg.?.eql(other.fg.?) else false;
        const bg_eq = if (self.bg == null and other.bg == null) true else if (self.bg != null and other.bg != null) self.bg.?.eql(other.bg.?) else false;
        return fg_eq and bg_eq and self.reversed == other.reversed;
    }
};

pub const Cell = struct {
    char: u21 = ' ',
    style: Style = .{},

    pub fn eql(self: Cell, other: Cell) bool {
        return self.char == other.char and self.style.eql(other.style);
    }
};

pub const Tui = struct {
    stdout: std.fs.File,
    stdin: std.fs.File,
    original_termios: std.posix.termios,
    allocator: std.mem.Allocator,

    width: u16 = 0,
    height: u16 = 0,

    back_buffer:  []Cell = &.{},
    front_buffer: []Cell = &.{},

    pub fn init(allocator: std.mem.Allocator) !*Tui {
        const tui = try allocator.create(Tui);
        tui.* = .{
            .stdout = .{ .handle = std.posix.STDOUT_FILENO },
            .stdin = .{ .handle = std.posix.STDIN_FILENO },
            .original_termios = try std.posix.tcgetattr(std.posix.STDIN_FILENO),
            .allocator = allocator,
        };

        var raw = tui.original_termios;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.oflag.OPOST = false;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;

        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
        try tui.stdout.writeAll("\x1b[?1049h\x1b[?25l"); // Alt screen, hide cursor

        try tui.resize();

        return tui;
    }

    pub fn deinit(self: *Tui) void {
        self.stdout.writeAll("\x1b[?1049l\x1b[?25h") catch {};
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original_termios) catch {};
        if (self.back_buffer.len > 0) self.allocator.free(self.back_buffer);
        if (self.front_buffer.len > 0) self.allocator.free(self.front_buffer);
        self.allocator.destroy(self);
    }

    pub fn resize(self: *Tui) !void {
        var size: std.posix.winsize = undefined;
        if (std.posix.system.ioctl(self.stdout.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&size)) != 0) {
            size = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
        }

        if (size.row == self.height and size.col == self.width) return;

        self.width = size.col;
        self.height = size.row;

        const new_len = @as(usize, self.width) * @as(usize, self.height);
        self.back_buffer = try self.allocator.realloc(self.back_buffer, new_len);
        self.front_buffer = try self.allocator.realloc(self.front_buffer, new_len);

        @memset(self.back_buffer, Cell{});
        @memset(self.front_buffer, Cell{ .char = 0 }); // Force redraw on first flush
    }

    pub fn setCell(self: *Tui, x: u16, y: u16, char: u21, style: Style) void {
        if (x >= self.width or y >= self.height) return;
        self.back_buffer[y * self.width + x] = .{ .char = char, .style = style };
    }

    pub fn writeString(self: *Tui, x: u16, y: u16, str: []const u8, style: Style) void {
        var cur_x = x;
        var utf8 = std.unicode.Utf8View.init(str) catch return;
        var iter = utf8.iterator();
        while (iter.nextCodepoint()) |cp| {
            if (cur_x >= self.width) break;
            self.setCell(cur_x, y, cp, style);
            cur_x += 1;
        }
    }

    pub fn flush(self: *Tui) !void {
        var scratch_buffer: [8192]u8 = undefined;
        var w = self.stdout.writer(&scratch_buffer);
        var current_style: Style = .{};
        var cursor_x: u16 = 9999;
        var cursor_y: u16 = 9999;

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const idx = y * self.width + x;
                const back = self.back_buffer[idx];
                const front = self.front_buffer[idx];

                if (!back.eql(front)) {
                    // Move cursor if needed
                    if (cursor_x != x or cursor_y != y) {
                        try w.interface.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
                    }

                    // Update style if needed
                    if (!back.style.eql(current_style)) {
                        try w.interface.writeAll("\x1b[0m");
                        if (back.style.fg) |fg| {
                            try w.interface.print("\x1b[38;2;{d};{d};{d}m", .{ fg.r, fg.g, fg.b });
                        }
                        if (back.style.bg) |bg| {
                            try w.interface.print("\x1b[48;2;{d};{d};{d}m", .{ bg.r, bg.g, bg.b });
                        }
                        if (back.style.reversed) {
                            try w.interface.writeAll("\x1b[7m");
                        }
                        current_style = back.style;
                    }

                    // Write character
                    var buf: [4]u8 = undefined;
                    const len = try std.unicode.utf8Encode(back.char, &buf);
                    try w.interface.writeAll(buf[0..len]);

                    self.front_buffer[idx] = back;
                    cursor_x = @as(u16, @intCast(x)) + 1;
                    cursor_y = @as(u16, @intCast(y));
                }
            }
        }

        try w.interface.flush();
        @memset(self.back_buffer, Cell{});
    }

    pub fn pollKey(self: *Tui, timeout_ms: u32) !?u21 {
        var fds = [_]std.posix.pollfd{.{
            .fd = self.stdin.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};

        const ready = try std.posix.poll(&fds, @intCast(timeout_ms));
        if (ready == 0) return null;

        var buf: [16]u8 = undefined;
        const n = try self.stdin.read(&buf);
        if (n == 0) return null;

        if (buf[0] == 0x1b and n > 1) {
            if (buf[1] == '[') {
                if (buf[2] == 'A') return 'k'; // Up
                if (buf[2] == 'B') return 'j'; // Down
                if (buf[2] == 'C') return 'l'; // Right
                if (buf[2] == 'D') return 'h'; // Left
            }
        }

        if (buf[0] < 32) {
            if (buf[0] == 14) return 'n' | 0x1000; // C-n
            if (buf[0] == 16) return 'p' | 0x1000; // C-p
            if (buf[0] == 3)  return 0x03;         // C-c
        }

        return buf[0];
    }
};
