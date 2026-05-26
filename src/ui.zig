const std       = @import("std");
const tui       = @import("tui.zig");
const Config    = @import("config.zig").Config;
const Browser   = @import("browser.zig").Browser;
const FileEntry = @import("browser.zig").FileEntry;
const builtin   = @import("builtin");

pub fn render(app_tui: *tui.Tui, browser: *Browser, config: *Config, full: bool) !void {
    const size = struct { w: u16, h: u16 }{ .w = app_tui.width, .h = app_tui.height };
    
    // Viewport height (leaving space for heading, and potentially the prompt/error at the bottom)
    const has_bottom_bar = browser.prompt_mode != .none or browser.error_message != null;
    const viewport_h = if (size.h > (if (has_bottom_bar) @as(u16, 2) else @as(u16, 1))) size.h - (if (has_bottom_bar) @as(u16, 2) else @as(u16, 1)) else 0;
    
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
        if (curr >= browser.scroll_offset and curr < browser.scroll_offset + viewport_h) {
            const y = @as(u16, @intCast(curr - browser.scroll_offset + 1));
            try renderEntry(app_tui, browser, &browser.entries.items[curr], curr, config, y);
        }
    }

    // Render Bottom Bar (Prompt or Error)
    if (has_bottom_bar) {
        const py = size.h - 1;
        // Clear bottom line
        var clr_x: u16 = 0;
        while (clr_x < size.w) : (clr_x += 1) app_tui.setCell(clr_x, py, ' ', .{});
        
        if (browser.error_message) |msg| {
            app_tui.writeString(0, py, "Error: ", .{ .fg = config.theme.default_fg, .bold = true });
            app_tui.writeString(7, py, msg, .{ .fg = config.theme.error_fg, .bold = true });
        } else {
            const prompt_str = switch (browser.prompt_mode) {
                .create_file => "Create file: ",
                .create_dir => "Create directory: ",
                else => unreachable,
            };
            app_tui.writeString(0, py, prompt_str, .{ .fg = config.theme.heading, .bold = true });
            
            var x = @as(u16, @intCast(prompt_str.len));
            const buf_items = browser.prompt_buffer.items;
            const buf_count = std.unicode.utf8CountCodepoints(buf_items) catch 0;
            
            var iter = (std.unicode.Utf8View.init(buf_items) catch unreachable).iterator();
            var cur_cp_idx: usize = 0;
            while (iter.nextCodepoint()) |cp| {
                if (cur_cp_idx == browser.char_offset and browser.is_cursor_visible) {
                    app_tui.setCell(x, py, cp, .{ .fg = config.theme.default_fg, .reversed = true });
                } else {
                    app_tui.setCell(x, py, cp, .{ .fg = config.theme.default_fg });
                }
                x += 1;
                cur_cp_idx += 1;
            }
            
            if (browser.char_offset == buf_count and browser.is_cursor_visible) {
                app_tui.setCell(x, py, ' ', .{ .reversed = true });
            }
        }
    }
}

fn renderEntry(app_tui: *tui.Tui, browser: *Browser, entry: *FileEntry, i: usize, config: *Config, y: u16) !void {
    const is_selected = (i == browser.selected_index) and (browser.prompt_mode == .none) and (browser.error_message == null);
    const is_marked = browser.marked_for_deletion.contains(entry.full_path);
    
    const base_style = tui.Style{ .fg = config.theme.default_fg };
    const mark_style = tui.Style{ .fg = config.theme.error_fg, .underlined = true };

    if (is_marked) {
        app_tui.setCell(0, y, 'D', mark_style);
        app_tui.setCell(1, y, ' ', mark_style);
    } else {
        app_tui.setCell(0, y, ' ', base_style);
        app_tui.setCell(1, y, ' ', base_style);
    }

    var x: u16 = 2;

    // Permissions (Cached)
    const p = entry.perm_str;
    const d_char = p[0];
    app_tui.setCell(x, y, d_char, .{ 
        .fg = if (is_marked) config.theme.error_fg else if (d_char == 'd') config.theme.priv_d else config.theme.priv_dash, 
        .bold = d_char == 'd',
        .underlined = is_marked,
    });
    x += 1;
    const p_chars = "rwxrwxrwx";
    for (0..9) |pi| {
        const char_val = p[pi+1];
        var style = tui.Style{ .underlined = is_marked };
        if (is_marked) {
            style.fg = config.theme.error_fg;
        } else if (char_val != '-') {
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
    app_tui.writeString(x, y, nlink_text, .{ 
        .fg = if (is_marked) config.theme.error_fg else config.theme.numbers, 
        .bold = true, 
        .underlined = is_marked 
    });
    x += @as(u16, @intCast(nlink_text.len));

    app_tui.writeString(x, y, " l l ", .{ .fg = if (is_marked) config.theme.error_fg else base_style.fg, .underlined = is_marked });
    x += 5;

    // Size (Cached & Padded)
    for (0..browser.max_size_len - entry.size_str.len) |_| { 
        app_tui.setCell(x, y, ' ', .{ .fg = if (is_marked) config.theme.error_fg else base_style.fg, .underlined = is_marked }); 
        x += 1; 
    }
    app_tui.writeString(x, y, entry.size_str, .{ 
        .fg = if (is_marked) config.theme.error_fg else config.theme.numbers, 
        .bold = true, 
        .underlined = is_marked 
    });
    x += @as(u16, @intCast(entry.size_str.len));

    app_tui.writeString(x, y, " ", .{ .fg = if (is_marked) config.theme.error_fg else base_style.fg, .underlined = is_marked });
    x += 1;
    app_tui.writeString(x, y, &entry.date_str, .{ 
        .fg = if (is_marked) config.theme.error_fg else config.theme.datetime, 
        .bold = true, 
        .underlined = is_marked 
    });
    x += @as(u16, @intCast(entry.date_str.len));
    app_tui.writeString(x, y, "  ", .{ .fg = if (is_marked) config.theme.error_fg else base_style.fg, .underlined = is_marked });
    x += 2;

    // Tree visuals (Skip mark coloring/underline as requested "excluding the tree if there is")
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

    // Icon
    const icon_info = getIconInfo(entry.*, config);
    const icon_color = if (is_marked) config.theme.error_fg else (icon_info.color orelse (if (entry.is_dir) config.theme.directories else config.theme.default_fg));
    app_tui.writeString(x, y, icon_info.char, .{ .fg = icon_color, .underlined = is_marked });
    x += @as(u16, @intCast(std.unicode.utf8CountCodepoints(icon_info.char) catch 1));
    app_tui.writeString(x, y, "  ", .{ .fg = if (is_marked) config.theme.error_fg else base_style.fg, .underlined = is_marked });
    x += 2;

    const name_color = if (is_marked) 
        config.theme.error_fg 
    else if (entry.is_dir) 
        config.theme.directories 
    else if ((entry.mode & 0o111) != 0) 
        config.theme.exec_fg 
    else 
        config.theme.default_fg;

    const name_style = tui.Style{ .fg = name_color, .underlined = is_marked };
    const name_to_render = if (is_selected and browser.is_editing) browser.edit_buffer.items else entry.name;
    const name_count = std.unicode.utf8CountCodepoints(name_to_render) catch 0;

    if (is_selected) {
        var iter = (std.unicode.Utf8View.init(name_to_render) catch unreachable).iterator();
        var cur_cp_idx: usize = 0;
        
        while (iter.nextCodepoint()) |cp| {
            if (cur_cp_idx == browser.char_offset and browser.is_cursor_visible) {
                app_tui.setCell(x, y, cp, .{ .fg = name_style.fg, .reversed = true, .underlined = is_marked });
            } else {
                app_tui.setCell(x, y, cp, name_style);
            }
            x += 1;
            cur_cp_idx += 1;
        }
        
        // Handle cursor at the end
        if (browser.char_offset == name_count and browser.is_cursor_visible) {
            app_tui.setCell(x, y, ' ', .{ .fg = name_style.fg, .reversed = true, .underlined = is_marked });
            x += 1;
        } else if (browser.char_offset == name_count) {
            app_tui.setCell(x, y, ' ', name_style);
            x += 1;
        }
    } else {
        app_tui.writeString(x, y, name_to_render, name_style);
        x += @as(u16, @intCast(name_count));
    }
    
    // Clear rest of line
    while (x < app_tui.width) : (x += 1) app_tui.setCell(x, y, ' ', base_style);
}

fn getIconInfo(entry: FileEntry, config: *Config) @import("config.zig").IconInfo {
    if (entry.is_dir) return config.icons.get("directory") orelse .{ .char = "" };
    
    // 1. Try full name match (handles .gitignore, LICENSE, etc)
    if (config.icons.get(entry.name)) |info| return info;
    
    // 2. Try extension match
    const ext = std.fs.path.extension(entry.name);
    if (ext.len > 0) {
        if (config.icons.get(ext)) |info| return info;
    }
    
    // 3. Fallback to default
    return config.icons.get("default") orelse .{ .char = "" };
}
