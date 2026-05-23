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
    
    var reload_requested = std.atomic.Value(bool).init(false);
    const watch_thread = try std.Thread.spawn(.{}, watchConfig, .{&reload_requested});
    watch_thread.detach();

    try browser.refresh(null);

    run(allocator, config, browser, &app_tui, &reload_requested) catch |err| {
        app_tui.deinit();
        return err;
    };
    
    app_tui.deinit();
}

fn run(allocator: std.mem.Allocator, config: *Config, browser: *Browser, app_tui_ptr: **tui.Tui, reload_requested: *std.atomic.Value(bool)) !void {
    var full_redraw = true;

    while (true) {
        if (reload_requested.swap(false, .monotonic)) {
            config.reload() catch {};
            full_redraw = true;
        }

        const key_raw = try app_tui_ptr.*.pollKey(100);

        if (key_raw) |kr| {
            const key: tui.Key = @enumFromInt(kr);
            if (key == .ctrl_c or key == @as(tui.Key, @enumFromInt('q')) or key == .esc) break;

            if (key == @as(tui.Key, @enumFromInt('j')) or key == @as(tui.Key, @enumFromInt('n')) or key == .ctrl_n or key == .down) {
                browser.moveDown();
            } else if (key == @as(tui.Key, @enumFromInt('k')) or key == @as(tui.Key, @enumFromInt('p')) or key == .ctrl_p or key == .up) {
                browser.moveUp();
            } else if (key == @as(tui.Key, @enumFromInt('h'))) {
                try browser.cdUp();
                full_redraw = true;
            } else if (key == .tab) {
                try browser.toggleExpand();
                full_redraw = true;
            } else if (key == @as(tui.Key, @enumFromInt('l')) or key == .ret) {
                const action = try browser.openSelected();
                switch (action) {
                    .none => {
                        full_redraw = true;
                    },
                    .editor => |path| {
                        defer allocator.free(path);
                        app_tui_ptr.*.deinit();
                        const editor = std.posix.getenv("EDITOR") orelse "vi";
                        var child = std.process.Child.init(&.{ editor, path }, allocator);
                        _ = try child.spawnAndWait();
                        app_tui_ptr.* = try tui.Tui.init(allocator);
                        full_redraw = true;
                    },
                }
            } else if (key == .ctrl_f or key == .right) {
                browser.moveCharForward();
            } else if (key == .ctrl_b or key == .left) {
                browser.moveCharBackward();
            } else if (key == .ctrl_a) {
                browser.moveLineStart();
            } else if (key == .ctrl_e) {
                browser.moveLineEnd();
            }
        }

        if (key_raw != null or full_redraw) {
            try ui.render(app_tui_ptr.*, browser, config, full_redraw);
            try app_tui_ptr.*.flush();
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
