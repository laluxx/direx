const std = @import("std");
const tui = @import("tui.zig");
const Config = @import("config.zig").Config;
const Browser = @import("browser.zig").Browser;
const ui = @import("ui.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = try Config.load(allocator);
    defer config.deinit();

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    var browser = try Browser.init(allocator, cwd);
    defer browser.deinit();

    var app_tui = try tui.Tui.init(allocator);
    defer app_tui.deinit();

    var reload_requested = std.atomic.Value(bool).init(false);
    const watch_thread = try std.Thread.spawn(.{}, watchConfig, .{&reload_requested});
    watch_thread.detach();

    // Wrap the main loop to ensure app_tui.deinit() is called on error
    run(allocator, config, browser, app_tui, &reload_requested) catch |err| {
        // app_tui.deinit() is already called by defer, but we want to be sure
        // before the stack trace is printed.
        app_tui.deinit();
        return err;
    };
}

fn run(allocator: std.mem.Allocator, config: *Config, browser: *Browser, app_tui_ptr: *tui.Tui, reload_requested: *std.atomic.Value(bool)) !void {
    var app_tui = app_tui_ptr;
    var full_redraw = true;

    while (true) {
        if (reload_requested.swap(false, .monotonic)) {
            config.reload() catch {};
            full_redraw = true;
        }

        const key = try app_tui.pollKey(100);

        if (key) |k| {
            if (k == 0x03 or k == 'q' or k == 27) break;

            if (k == 'j' or k == 'n' or k == ('n' | 0x1000)) {
                browser.moveDown();
            } else if (k == 'k' or k == 'p' or k == ('p' | 0x1000)) {
                browser.moveUp();
            } else if (k == 'h') {
                try browser.cdUp();
                full_redraw = true;
            } else if (k == '\t') {
                try browser.toggleExpand();
                full_redraw = true;
            } else if (k == 'l' or k == '\r') {
                const action = try browser.openSelected();
                switch (action) {
                    .none => {
                        full_redraw = true;
                    },
                    .editor => |path| {
                        defer allocator.free(path);
                        app_tui.deinit();
                        const editor = std.posix.getenv("EDITOR") orelse "vi";
                        var child = std.process.Child.init(&.{ editor, path }, allocator);
                        _ = try child.spawnAndWait();
                        app_tui = try tui.Tui.init(allocator);
                        full_redraw = true;
                    },
                }
            }
        }

        if (key != null or full_redraw) {
            try ui.render(app_tui, browser, config, full_redraw);
            try app_tui.flush();
            full_redraw = false;
        }
    }
}

fn watchConfig(reload_requested: *std.atomic.Value(bool)) !void {
    const home = std.posix.getenv("HOME") orelse return;
    var path_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&path_buf);
    const config_dir = std.fs.path.join(fba.allocator(), &.{ home, ".config", "direx" }) catch return;

    const fd = std.posix.inotify_init1(std.os.linux.IN.CLOEXEC) catch return;
    defer std.posix.close(fd);

    _ = std.posix.inotify_add_watch(fd, config_dir, std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE) catch return;

    var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
    while (true) {
        const bytes_read = std.posix.read(fd, &buf) catch break;
        if (bytes_read == 0) break;
        reload_requested.store(true, .monotonic);
    }
}
