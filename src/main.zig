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

    const initial_cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(initial_cwd);
    
    var browser = try Browser.init(allocator, initial_cwd);
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
    
    const final_path = try allocator.dupe(u8, browser.path);
    defer allocator.free(final_path);

    app_tui.deinit();

    // 4. If the directory changed, replace process with shell
    if (!std.mem.eql(u8, final_path, initial_cwd)) {
        const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
        const shell_z = try allocator.dupeZ(u8, shell);
        defer allocator.free(shell_z);

        const argv = &[_:null]?[*:0]const u8{ shell_z.ptr, null };

        // Re-construct environment
        var env = try std.process.getEnvMap(allocator);
        defer env.deinit();
        
        var env_list = try std.ArrayList(?[*:0]const u8).initCapacity(allocator, env.count() + 1);
        defer {
            for (env_list.items) |line| {
                if (line) |ptr| allocator.free(std.mem.span(ptr));
            }
            env_list.deinit(allocator);
        }

        var env_ptr = env.iterator();
        while (env_ptr.next()) |entry| {
            const line = try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
            defer allocator.free(line);
            const line_z = try allocator.dupeZ(u8, line);
            try env_list.append(allocator, line_z.ptr);
        }
        try env_list.append(allocator, null);

        std.posix.chdir(final_path) catch {};
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(env_list.items.ptr);
        _ = std.posix.execvpeZ(shell_z, argv.ptr, envp) catch {};
    }
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
            if (key == .ctrl_c or (key == @as(tui.Key, @enumFromInt('q')) and !browser.is_editing)) break;

            if (browser.is_editing) {
                switch (key) {
                    .esc, .ctrl_g => {
                        try browser.stopEditing(true);
                        full_redraw = true;
                    },
                    .up, .ctrl_p => {
                        try browser.stopEditing(true);
                        browser.moveUp();
                        full_redraw = true;
                    },
                    .down, .ctrl_n => {
                        try browser.stopEditing(true);
                        browser.moveDown();
                        full_redraw = true;
                    },
                    .left, .ctrl_b => {
                        browser.moveCharBackward();
                    },
                    .right, .ctrl_f => {
                        browser.moveCharForward();
                    },
                    .ctrl_a => {
                        browser.moveLineStart();
                    },
                    .ctrl_e => {
                        browser.moveLineEnd();
                    },
                    .backspace => {
                        try browser.backspace();
                    },
                    .ctrl_d => {
                        try browser.deleteCharUnderCursor();
                    },
                    .ret => {
                        try browser.stopEditing(true);
                        full_redraw = true;
                    },
                    else => {
                        if (kr >= 32 and kr < 0x1000) {
                            try browser.insertChar(@intCast(kr));
                        }
                    },
                }
            } else {
                // Normal Mode
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
                } else if (key == @as(tui.Key, @enumFromInt('i'))) {
                    try browser.startEditing();
                } else if (key == .backspace) {
                    try browser.startEditing();
                    try browser.backspace();
                } else if (key == .ctrl_d) {
                    try browser.startEditing();
                    try browser.deleteCharUnderCursor();
                }
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
