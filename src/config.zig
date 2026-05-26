const std = @import("std");
const tui = @import("tui.zig");

pub const Theme = struct {
    directories: tui.Color,
    datetime:    tui.Color,
    numbers:     tui.Color,
    default_fg:  tui.Color,
    priv_d:      tui.Color,
    priv_r:      tui.Color,
    priv_w:      tui.Color,
    priv_dash:   tui.Color,
    priv_exec:   tui.Color,
    heading:     tui.Color,
    exec_fg:     tui.Color,
    error_fg:    tui.Color,
};

pub const IconInfo = struct {
    char: []const u8,
    color: ?tui.Color = null,
};

pub const Config = struct {
    theme: Theme,
    icons: std.StringHashMap(IconInfo),
    trash_path: []const u8,
    allocator: std.mem.Allocator,

    pub fn load(allocator: std.mem.Allocator) !*Config {
        const config = try allocator.create(Config);
        config.* = .{
            .theme = undefined,
            .icons = std.StringHashMap(IconInfo).init(allocator),
            .trash_path = "",
            .allocator = allocator,
        };

        // Set default trash path
        const home = std.posix.getenv("HOME") orelse ".";
        config.trash_path = try std.fs.path.join(allocator, &.{ home, ".config", "direx", "trash" });

        // Set defaults
        config.theme = .{
            .directories = tui.Color.fromRgb(0x95, 0x87, 0xDD),
            .datetime    = tui.Color.fromRgb(0x95, 0x87, 0xDD),
            .numbers     = tui.Color.fromRgb(0x41, 0xb0, 0xf3),
            .default_fg  = tui.Color.fromRgb(0xe6, 0xe6, 0xe8),
            .priv_d      = tui.Color.fromRgb(0x6b, 0xd9, 0xdb),
            .priv_r      = tui.Color.fromRgb(0x6d, 0xd7, 0x97),
            .priv_w      = tui.Color.fromRgb(0xea, 0xe4, 0x6a),
            .priv_dash   = tui.Color.fromRgb(0x61, 0x5b, 0x75),
            .priv_exec   = tui.Color.fromRgb(0xe8, 0x4c, 0x58),
            .heading     = tui.Color.fromRgb(0x49, 0xbd, 0xb0),
            .exec_fg     = tui.Color.fromRgb(0x65, 0xE6, 0xA7),
            .error_fg    = tui.Color.fromRgb(0xe8, 0x4c, 0x58),
        };

        // Initial default icons
        try config.putIcon(".zig",      "", tui.Color.fromRgb(0xf7, 0xa4, 0x1d));
        try config.putIcon(".md",       "", tui.Color.fromRgb(0x42, 0xa5, 0xf5));
        try config.putIcon("directory", "", tui.Color.fromRgb(0x95, 0x87, 0xDD));
        try config.putIcon("default",   "", null);

        try config.ensureConfigExists();
        try config.reload();
        return config;
    }

    pub fn deinit(self: *Config) void {
        var iter = self.icons.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.char);
        }
        self.icons.deinit();
        self.allocator.free(self.trash_path);
        self.allocator.destroy(self);
    }

    fn putIcon(self: *Config, key: []const u8, char: []const u8, color: ?tui.Color) !void {
        const k = try self.allocator.dupe(u8, key);
        const c = try self.allocator.dupe(u8, char);
        try self.icons.put(k, .{ .char = c, .color = color });
    }

    fn ensureConfigExists(self: *Config) !void {
        const home = std.posix.getenv("HOME") orelse return;
        const config_dir_path = try std.fs.path.join(self.allocator, &.{ home, ".config", "direx" });
        defer self.allocator.free(config_dir_path);

        std.fs.makeDirAbsolute(config_dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const config_path = try std.fs.path.join(self.allocator, &.{ config_dir_path, "config.yaml" });
        defer self.allocator.free(config_path);

        const file = std.fs.createFileAbsolute(config_path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => return,
            else => return err,
        };
        defer file.close();

        const default_trash = try std.fs.path.join(self.allocator, &.{ home, ".config", "direx", "trash" });
        defer self.allocator.free(default_trash);

        const config_template =
            \\theme:
            \\  directories: "#9587DD"
            \\  datetime:    "#9587DD"
            \\  numbers:     "#41b0f3"
            \\  default_fg:  "#e6e6e8"
            \\  privileges:
            \\    d:      "#6bd9db"
            \\    r:      "#6dd797"
            \\    w:      "#eae46a"
            \\    dash:   "#615B75"
            \\    exec:   "#e84c58"
            \\  heading:  "#49bdb0"
            \\  exec_fg:  "#65E6A7"
            \\  error_fg: "#e84c58"
            \\
            \\trash_path: "{s}"
            \\
            \\icons:
            \\  .zig: " #FFA500"
            \\  .c:   " #6A9FB5"
            \\  .h:   " #AA759F"
            \\  .o:   " #838484"
            \\  .md:  " #e6e6e8"
            \\  .txt: " #e6e6e8"
            \\  .org: " #C6E87A"
            \\  .git: " #615B75"
            \\  .gitignore: " #EB595A"
            \\  directory: " #9587DD"
            \\  default:   " #e6e6e8"
            \\
        ;

        const output = try std.fmt.allocPrint(self.allocator, config_template, .{default_trash});
        defer self.allocator.free(output);
        try file.writeAll(output);
    }

    pub fn reload(self: *Config) !void {
        const home = std.posix.getenv("HOME") orelse return error.HomeNotFound;
        const config_dir_path = try std.fs.path.join(self.allocator, &.{ home, ".config", "direx" });
        defer self.allocator.free(config_dir_path);

        var config_dir = std.fs.openDirAbsolute(config_dir_path, .{}) catch return;
        defer config_dir.close();

        const content = config_dir.readFileAlloc("config.yaml", self.allocator, .unlimited) catch return;
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        var current_section: enum { none, theme, privileges, icons } = .none;

        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r");
            if (line.len == 0 or line[0] == '#') continue;

            const indent = getIndent(raw_line);

            if (std.mem.startsWith(u8, line, "theme:")) {
                current_section = .theme;
                continue;
            } else if (std.mem.startsWith(u8, line, "privileges:") and current_section == .theme) {
                current_section = .privileges;
                continue;
            } else if (std.mem.startsWith(u8, line, "icons:")) {
                current_section = .icons;
                continue;
            } else if (std.mem.startsWith(u8, line, "trash_path:")) {
                var parts = std.mem.splitScalar(u8, line, ':');
                _ = parts.next();
                const val = std.mem.trim(u8, parts.rest(), " \"'");
                if (val.len > 0) {
                    self.allocator.free(self.trash_path);
                    self.trash_path = try self.allocator.dupe(u8, val);
                }
                continue;
            }

            if (current_section == .none) continue;

            var parts = std.mem.splitScalar(u8, line, ':');
            const key = std.mem.trim(u8, parts.next() orelse continue, " ");
            const val_raw = std.mem.trim(u8, parts.rest(), " \"'");

            if (val_raw.len == 0) continue;

            switch (current_section) {
                .theme => {
                    if (indent == 2) {
                        if (std.mem.eql(u8, key, "directories")) self.theme.directories = parseHex(val_raw) orelse self.theme.directories;
                        if (std.mem.eql(u8, key, "datetime"))    self.theme.datetime    = parseHex(val_raw) orelse self.theme.datetime;
                        if (std.mem.eql(u8, key, "numbers"))     self.theme.numbers     = parseHex(val_raw) orelse self.theme.numbers;
                        if (std.mem.eql(u8, key, "default_fg"))  self.theme.default_fg  = parseHex(val_raw) orelse self.theme.default_fg;
                        if (std.mem.eql(u8, key, "heading"))     self.theme.heading     = parseHex(val_raw) orelse self.theme.heading;
                        if (std.mem.eql(u8, key, "exec_fg"))     self.theme.exec_fg     = parseHex(val_raw) orelse self.theme.exec_fg;
                        if (std.mem.eql(u8, key, "error_fg"))    self.theme.error_fg    = parseHex(val_raw) orelse self.theme.error_fg;
                    }
                },
                .privileges => {
                    if (indent == 4) {
                        if (std.mem.eql(u8, key, "d"))    self.theme.priv_d    = parseHex(val_raw) orelse self.theme.priv_d;
                        if (std.mem.eql(u8, key, "r"))    self.theme.priv_r    = parseHex(val_raw) orelse self.theme.priv_r;
                        if (std.mem.eql(u8, key, "w"))    self.theme.priv_w    = parseHex(val_raw) orelse self.theme.priv_w;
                        if (std.mem.eql(u8, key, "dash")) self.theme.priv_dash = parseHex(val_raw) orelse self.theme.priv_dash;
                        if (std.mem.eql(u8, key, "exec")) self.theme.priv_exec = parseHex(val_raw) orelse self.theme.priv_exec;
                    } else if (indent == 2) {
                        current_section = .theme; // Back to theme
                    }
                },
                .icons => {
                    if (indent == 2) {
                        // Split value into char and optional hex
                        var val_parts = std.mem.splitScalar(u8, val_raw, ' ');
                        const char = val_parts.next() orelse "";
                        const hex = val_parts.next();

                        const icon_key = try self.allocator.dupe(u8, key);
                        const icon_char = try self.allocator.dupe(u8, char);
                        const icon_color = if (hex) |h| parseHex(h) else null;

                        if (self.icons.getPtr(icon_key)) |old| {
                            self.allocator.free(old.*.char);
                            old.* = .{ .char = icon_char, .color = icon_color };
                            self.allocator.free(icon_key);
                        } else {
                            try self.icons.put(icon_key, .{ .char = icon_char, .color = icon_color });
                        }
                    }
                },
                else => {},
            }
        }
    }

    fn getIndent(line: []const u8) usize {
        var count: usize = 0;
        for (line) |c| {
            if (c == ' ') count += 1 else break;
        }
        return count;
    }

    fn parseHex(s: []const u8) ?tui.Color {
        if (s.len != 7 or s[0] != '#') return null;
        const r = std.fmt.parseInt(u8, s[1..3], 16) catch return null;
        const g = std.fmt.parseInt(u8, s[3..5], 16) catch return null;
        const b = std.fmt.parseInt(u8, s[5..7], 16) catch return null;
        return tui.Color.fromRgb(r, g, b);
    }
};
