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
    bold: bool = false,
    underlined: bool = false,

    pub fn eql(self: Style, other: Style) bool {
        const fg_eq = if (self.fg == null and other.fg == null) true else if (self.fg != null and other.fg != null) self.fg.?.eql(other.fg.?) else false;
        const bg_eq = if (self.bg == null and other.bg == null) true else if (self.bg != null and other.bg != null) self.bg.?.eql(other.bg.?) else false;
        return fg_eq and bg_eq and self.reversed == other.reversed and self.bold == other.bold and self.underlined == other.underlined;
    }
};

pub const Cell = struct {
    char: u21 = ' ',
    style: Style = .{},

    pub fn eql(self: Cell, other: Cell) bool {
        return self.char == other.char and self.style.eql(other.style);
    }
};

pub const Key = enum(u32) {
    none = 0,
    up = 0x1001,
    down = 0x1002,
    right = 0x1003,
    left = 0x1004,
    ctrl_n = 14,
    ctrl_p = 16,
    ctrl_f = 6,
    ctrl_b = 2,
    ctrl_a = 1,
    ctrl_e = 5,
    ctrl_d = 4,
    ctrl_k = 11,
    ctrl_y = 25,
    ctrl_g = 7,
    ctrl_slash = 31,
    ctrl_question = 0x1005, // Custom for redo
    meta_d = 0x2001,
    ret = 13,
    tab = 9,
    esc = 27,
    backspace = 127,
    ctrl_c = 3,
    g = 'g',
    G = 'G',
    _,
};

pub const Tui = struct {
    stdout: std.fs.File,
    stdin: std.fs.File,
    original_termios: std.posix.termios,
    allocator: std.mem.Allocator,

    width: u16 = 0,
    height: u16 = 0,

    back_buffer: []Cell = &.{},
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
        @memset(self.front_buffer, Cell{ .char = 0 }); // Force redraw
    }

    pub fn clear(self: *Tui) void {
        @memset(self.back_buffer, Cell{});
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
        var scratch_buffer: [16384]u8 = undefined;
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
                    if (cursor_x != x or cursor_y != y) {
                        try w.interface.print("\x1b[{d};{d}H", .{ y + 1, x + 1 });
                    }

                    if (!back.style.eql(current_style)) {
                        try w.interface.writeAll("\x1b[0m");
                        if (back.style.fg) |fg| try w.interface.print("\x1b[38;2;{d};{d};{d}m", .{ fg.r, fg.g, fg.b });
                        if (back.style.bg) |bg| try w.interface.print("\x1b[48;2;{d};{d};{d}m", .{ bg.r, bg.g, bg.b });
                        if (back.style.reversed) try w.interface.writeAll("\x1b[7m");
                        if (back.style.bold) try w.interface.writeAll("\x1b[1m");
                        if (back.style.underlined) try w.interface.writeAll("\x1b[4m");
                        current_style = back.style;
                    }

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
    }

    pub fn pollKey(self: *Tui, timeout_ms: u32) !?u32 {
        var fds = [_]std.posix.pollfd{.{ .fd = self.stdin.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&fds, @intCast(timeout_ms)) == 0) return null;
        var buf: [16]u8 = undefined;
        const n = try self.stdin.read(&buf);
        if (n == 0) return null;
        if (buf[0] == 0x1b) {
            if (n > 1) {
                if (buf[1] == '[') {
                    if (buf[2] == 'A') return @intFromEnum(Key.up);
                    if (buf[2] == 'B') return @intFromEnum(Key.down);
                    if (buf[2] == 'C') return @intFromEnum(Key.right);
                    if (buf[2] == 'D') return @intFromEnum(Key.left);
                } else if (buf[1] == 'd') {
                    return @intFromEnum(Key.meta_d);
                } else if (buf[1] == '?') {
                    return @intFromEnum(Key.ctrl_question);
                }
            }
            return @intFromEnum(Key.esc);
        }
        if (buf[0] == 0x1f) return @intFromEnum(Key.ctrl_slash);
        return buf[0];
    }
};
