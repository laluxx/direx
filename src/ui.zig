const std       = @import("std");
const tui       = @import("tui.zig");
const Config    = @import("config.zig").Config;
const Browser   = @import("browser.zig").Browser;
const FileEntry = @import("browser.zig").FileEntry;
const builtin   = @import("builtin");

var frame_count: usize = 0;
var total_frame_time: i64 = 0;

pub fn render(app_tui: *tui.Tui, browser: *Browser, config: *Config, full: bool) !void {
    const start_time = if (builtin.mode == .Debug) std.time.Instant.now() catch null else null;
    const size = struct { w: u16, h: u16 }{ .w = app_tui.width, .h = app_tui.height };
    
    // Viewport height (leaving space for heading and debug stats)
    const viewport_h = size.h - 2;
    
    // Manage scrolling before any rendering
    const scroll_changed = browser.manageScroll(viewport_h);
    const force_full = full or scroll_changed;

    if (force_full) {
        app_tui.clear();
        app_tui.writeString(0, 0, browser.path, .{ .fg = config.theme.heading });
        app_tui.writeString(@as(u16, @intCast(browser.path.len)), 0, ":", .{ .fg = config.theme.heading });

        var i = browser.scroll_offset;
        var y: u16 = 1;
        while (i < browser.entries.items.len and y <= viewport_h) : ({ i += 1; y += 1; }) {
            try renderEntry(app_tui, browser, &browser.entries.items[i], i, config, y);
        }
    } else {
        // Surgical update within the viewport
        if (browser.prev_index) |prev| {
            if (prev >= browser.scroll_offset and prev < browser.scroll_offset + viewport_h) {
                const y = @as(u16, @intCast(prev - browser.scroll_offset + 1));
                try renderEntry(app_tui, browser, &browser.entries.items[prev], prev, config, y);
            }
        }
        const curr = browser.selected_index;
        const y = @as(u16, @intCast(curr - browser.scroll_offset + 1));
        try renderEntry(app_tui, browser, &browser.entries.items[curr], curr, config, y);
    }

    if (builtin.mode == .Debug) {
        if (start_time) |st| {
            const end_time = std.time.Instant.now() catch return;
            const diff = end_time.since(st);
            frame_count += 1;
            total_frame_time += @as(i64, @intCast(diff));
            var stats_buf: [128]u8 = undefined;
            const stats_text = try std.fmt.bufPrint(&stats_buf, "Frame: {d}ns | Avg: {d}ns | Scroll: {d} | Char: {d} | Size: {d}x{d}", .{ diff, @divTrunc(total_frame_time, @as(i64, @intCast(frame_count))), browser.scroll_offset, browser.char_offset, size.w, size.h });
            app_tui.writeString(0, size.h - 1, stats_text, .{ .fg = tui.Color.fromRgb(255, 255, 255), .bg = tui.Color.fromRgb(50, 50, 50) });
        }
    }
}

fn renderEntry(app_tui: *tui.Tui, browser: *Browser, entry: *FileEntry, i: usize, config: *Config, y: u16) !void {
    const is_selected = (i == browser.selected_index);
    const base_style = tui.Style{ .fg = config.theme.default_fg };

    var x: u16 = 2;

    // Permissions (Cached)
    const p = entry.perm_str;
    const d_char = p[0];
    app_tui.setCell(x, y, d_char, .{ 
        .fg = if (d_char == 'd') config.theme.priv_d else config.theme.priv_dash, 
        .bold = d_char == 'd' 
    });
    x += 1;
    const p_chars = "rwxrwxrwx";
    for (0..9) |pi| {
        const char_val = p[pi+1];
        var style = tui.Style{};
        if (char_val != '-') {
            style.fg = switch (p_chars[pi]) {
                'r' => config.theme.priv_r,
                'w' => config.theme.priv_w,
                'x' => config.theme.priv_exec,
                else => config.theme.priv_dash,
            };
        } else {
            style.fg = config.theme.priv_dash;
        }
        app_tui.setCell(x, y, char_val, style);
        x += 1;
    }

    // Nlink
    var nlink_buf: [16]u8 = undefined;
    const nlink_text = try std.fmt.bufPrint(&nlink_buf, " {d}", .{entry.nlink});
    app_tui.writeString(x, y, nlink_text, .{ .fg = config.theme.numbers, .bold = true });
    x += @as(u16, @intCast(nlink_text.len));

    app_tui.writeString(x, y, " l l ", base_style);
    x += 5;

    // Size (Cached & Padded)
    for (0..browser.max_size_len - entry.size_str.len) |_| { app_tui.setCell(x, y, ' ', base_style); x += 1; }
    app_tui.writeString(x, y, entry.size_str, .{ .fg = config.theme.numbers, .bold = true });
    x += @as(u16, @intCast(entry.size_str.len));

    const date_text = " May 23 13:22  ";
    app_tui.writeString(x, y, date_text, .{ .fg = config.theme.datetime, .bold = true });
    x += @as(u16, @intCast(date_text.len));

    // Tree visuals
    if (entry.level > 0) {
        for (1..entry.level) |depth| {
            var has_more_at_depth = false;
            var j = i + 1;
            while (j < browser.entries.items.len) : (j += 1) {
                const next = browser.entries.items[j];
                if (next.level == depth) {
                    has_more_at_depth = true;
                    break;
                }
                if (next.level < depth) break;
            }

            if (has_more_at_depth) {
                app_tui.writeString(x, y, "│ ", .{ .fg = config.theme.priv_dash });
            } else {
                app_tui.writeString(x, y, "  ", base_style);
            }
            x += 2;
        }

        var is_last = true;
        var j = i + 1;
        while (j < browser.entries.items.len) : (j += 1) {
            const next = browser.entries.items[j];
            if (next.level == entry.level) {
                is_last = false;
                break;
            } else if (next.level < entry.level) {
                break;
            }
        }
        app_tui.writeString(x, y, if (is_last) "└─" else "├─", .{ .fg = config.theme.priv_dash });
        x += 2;
    }

    // Icon (Cached lookup)
    if (entry.icon.len == 0) entry.icon = getIcon(entry.*, config);
    app_tui.writeString(x, y, entry.icon, .{ .fg = if (entry.is_dir) config.theme.directories else config.theme.default_fg });
    x += @as(u16, @intCast(try std.unicode.utf8CountCodepoints(entry.icon)));
    app_tui.writeString(x, y, "  ", base_style);
    x += 2;

    const name_style = if (entry.is_dir) tui.Style{ .fg = config.theme.directories } else tui.Style{ .fg = config.theme.default_fg };
    if (is_selected) {
        var iter = (std.unicode.Utf8View.init(entry.name) catch unreachable).iterator();
        var cur_cp_idx: usize = 0;
        const name_count = std.unicode.utf8CountCodepoints(entry.name) catch 0;
        
        while (iter.nextCodepoint()) |cp| {
            if (cur_cp_idx == browser.char_offset) {
                app_tui.setCell(x, y, cp, .{ .fg = name_style.fg, .reversed = true });
            } else {
                app_tui.setCell(x, y, cp, name_style);
            }
            x += 1;
            cur_cp_idx += 1;
        }
        
        // Handle cursor at the end (one past the last character)
        if (browser.char_offset == name_count) {
            app_tui.setCell(x, y, ' ', .{ .reversed = true });
            x += 1;
        }
    } else {
        app_tui.writeString(x, y, entry.name, name_style);
        x += @as(u16, @intCast(try std.unicode.utf8CountCodepoints(entry.name)));
    }
    
    // Clear rest of line
    while (x < app_tui.width) : (x += 1) app_tui.setCell(x, y, ' ', base_style);
}

fn getIcon(entry: FileEntry, config: *Config) []const u8 {
    if (entry.is_dir) return config.icons.get("directory") orelse "";
    const ext = std.fs.path.extension(entry.name);
    return config.icons.get(ext) orelse config.icons.get("default") orelse "";
}
