const std = @import("std");
const tui = @import("tui.zig");
const Config = @import("config.zig").Config;
const Browser = @import("browser.zig").Browser;
const ui = @import("ui.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize config
    var config = try Config.load(allocator);
    defer config.deinit();

    // Initialize browser
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    var browser = try Browser.init(allocator, cwd);
    defer browser.deinit();

    // Initialize TUI
    var app_tui = try tui.Tui.init(allocator);
    defer app_tui.deinit();

    // Start inotify thread for config watching
    var reload_requested = std.atomic.Value(bool).init(false);
    const watch_thread = try std.Thread.spawn(.{}, watchConfig, .{ allocator, &reload_requested });
    watch_thread.detach();

    while (true) {
        if (reload_requested.swap(false, .monotonic)) {
            config.reload() catch {};
        }

        try ui.render(app_tui, browser, config);
        try app_tui.flush();

        const key = try app_tui.pollKey(100);
        if (key) |k| {
            if (k == 0x03 or k == 'q' or k == 27) break; // C-c, q, Esc

            if (k == 'j' or k == 'n' or k == ('n' | 0x1000)) {
                browser.moveDown();
            } else if (k == 'k' or k == 'p' or k == ('p' | 0x1000)) {
                browser.moveUp();
            } else if (k == 'h') {
                try browser.cdUp();
            } else if (k == 'l' or k == '\r') {
                const action = try browser.openSelected();
                switch (action) {
                    .none => {},
                    .editor => |path| {
                        defer allocator.free(path);
                        app_tui.deinit();
                        const editor = std.posix.getenv("EDITOR") orelse "vi";
                        var child = std.process.Child.init(&.{ editor, path }, allocator);
                        _ = try child.spawnAndWait();
                        // Re-init TUI
                        app_tui = try tui.Tui.init(allocator);
                    },
                }
            }
        }
    }
}

fn watchConfig(allocator: std.mem.Allocator, reload_requested: *std.atomic.Value(bool)) !void {
    const home = std.posix.getenv("HOME") orelse return;
    const config_dir = try std.fs.path.join(allocator, &.{ home, ".config", "direx" });
    defer allocator.free(config_dir);

    const fd = try std.posix.inotify_init1(std.os.linux.IN.CLOEXEC);
    defer std.posix.close(fd);

    _ = try std.posix.inotify_add_watch(fd, config_dir, std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE);

    var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
    while (true) {
        const bytes_read = std.posix.read(fd, &buf) catch break;
        if (bytes_read == 0) break;
        reload_requested.store(true, .monotonic);
    }
}
