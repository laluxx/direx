const std       = @import("std");
const tui       = @import("tui.zig");
const Config    = @import("config.zig").Config;
const Browser   = @import("browser.zig").Browser;
const FileEntry = @import("browser.zig").FileEntry;
const builtin   = @import("builtin");

var frame_count: usize = 0;
var total_frame_time: i64 = 0;

pub fn render(app_tui: *tui.Tui, browser: *Browser, config: *Config) !void {
    const start_time = if (builtin.mode == .Debug) std.time.Instant.now() catch null else null;
    const size = struct { w: u16, h: u16 }{ .w = app_tui.width, .h = app_tui.height };

    // Render heading
    app_tui.writeString(0, 0, browser.path, .{ .fg = config.theme.heading });
    app_tui.writeString(@as(u16, @intCast(browser.path.len)), 0, ":", .{ .fg = config.theme.heading });

    // Render entries
    for (browser.entries.items, 0..) |entry, i| {
        const y = @as(u16, @intCast(i + 1));
        if (y >= size.h - 1) break; // Leave last line for stats in debug

        const is_selected = (i == browser.selected_index);
        const base_style = tui.Style{ .fg = config.theme.default_fg };

        var x: u16 = 2;

        // Permissions
        x = renderPermissions(app_tui, entry, is_selected, config, x, y);

        // Nlink
        var nlink_buf: [16]u8 = undefined;
        const nlink_text = try std.fmt.bufPrint(&nlink_buf, " {d}", .{entry.nlink});
        app_tui.writeString(x, y, nlink_text, .{ .fg = config.theme.numbers });
        x += @as(u16, @intCast(nlink_text.len));

        // User/Group
        const ug_text = " l l";
        app_tui.writeString(x, y, ug_text, base_style);
        x += @as(u16, @intCast(ug_text.len));

        // Size
        var size_buf: [16]u8 = undefined;
        const size_text = try std.fmt.bufPrint(&size_buf, " {d:>8}", .{entry.size});
        app_tui.writeString(x, y, size_text, .{ .fg = config.theme.numbers });
        x += @as(u16, @intCast(size_text.len));

        // Date
        app_tui.writeString(x, y, " ", base_style);
        x += 1;
        const date_text = "May 23 13:22"; // Placeholder for speed
        app_tui.writeString(x, y, date_text, .{ .fg = config.theme.datetime });
        x += @as(u16, @intCast(date_text.len));

        // Icon
        const icon = getIcon(entry, config);
        app_tui.writeString(x, y, "  ", base_style);
        x += 2;
        app_tui.writeString(x, y, icon, .{ .fg = if (entry.is_dir) config.theme.directories else config.theme.default_fg });
        x += @as(u16, @intCast(try std.unicode.utf8CountCodepoints(icon)));
        app_tui.writeString(x, y, "  ", base_style);
        x += 2;

        // Name
        const name_style = if (entry.is_dir) tui.Style{ .fg = config.theme.directories } else tui.Style{ .fg = config.theme.default_fg };
        if (is_selected) {
            if (entry.name.len > 0) {
                // First char as block
                var iter = (std.unicode.Utf8View.init(entry.name) catch unreachable).iterator();
                app_tui.setCell(x, y, iter.nextCodepoint().?, .{ .fg = name_style.fg, .reversed = true });
                app_tui.writeString(x + 1, y, entry.name[iter.i..], name_style);
            }
        } else {
            app_tui.writeString(x, y, entry.name, name_style);
        }
    }

    if (builtin.mode == .Debug) {
        if (start_time) |st| {
            const end_time = std.time.Instant.now() catch return;
            const diff = end_time.since(st);
            frame_count += 1;
            total_frame_time += @as(i64, @intCast(diff));

            var stats_buf: [128]u8 = undefined;
            const stats_text = try std.fmt.bufPrint(&stats_buf, "Frame: {d}ns | Avg: {d}ns | Size: {d}x{d}", .{ diff, @divTrunc(total_frame_time, @as(i64, @intCast(frame_count))), size.w, size.h });
            app_tui.writeString(0, size.h - 1, stats_text, .{ .fg = tui.Color.fromRgb(255, 255, 255), .bg = tui.Color.fromRgb(50, 50, 50) });
        }
    }
}

fn renderPermissions(app_tui: *tui.Tui, entry: FileEntry, _: bool, config: *Config, start_x: u16, y: u16) u16 {
    var x = start_x;

    const d_char: u21 = if (entry.is_dir) 'd' else '-';
    const d_style = if (entry.is_dir) tui.Style{ .fg = config.theme.priv_d } else tui.Style{ .fg = config.theme.priv_dash };
    app_tui.setCell(x, y, d_char, d_style);
    x += 1;

    const chars = "rwxrwxrwx";
    for (0..9) |i| {
        const bit = @as(u64, 1) << @as(u6, @intCast(8 - i));
        const has = (entry.mode & bit) != 0;
        const char: u21 = if (has) chars[i] else '-';

        var style = tui.Style{};
        if (!has) {
            style.fg = config.theme.priv_dash;
        } else {
            switch (chars[i]) {
                'r' => style.fg = config.theme.priv_r,
                'w' => style.fg = config.theme.priv_w,
                'x' => style.fg = config.theme.priv_exec,
                else => {},
            }
        }
        app_tui.setCell(x, y, char, style);
        x += 1;
    }
    return x;
}

fn getIcon(entry: FileEntry, config: *Config) []const u8 {
    if (entry.is_dir) {
        return config.icons.get("directory") orelse "";
    }
    const ext = std.fs.path.extension(entry.name);
    return config.icons.get(ext) orelse config.icons.get("default") orelse "";
}
