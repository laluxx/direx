const std     = @import("std");
const tui     = @import("tui.zig");
const Config  = @import("config.zig").Config;
const Browser = @import("browser.zig").Browser;
const ui      = @import("ui.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Parse Arguments
    var initial_path: ?[]const u8 = null;
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // Skip binary name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--print-last-dir")) {
            _ = args.next(); // Ignore for now
        } else {
            initial_path = arg;
        }
    }

    // 2. Start Config Loading
    var config = try Config.load(allocator);
    defer config.deinit();

    // 3. Prepare Browser
    const cwd = if (initial_path) |p| try allocator.dupe(u8, p) else try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);

    var browser = try Browser.init(allocator, cwd);
    defer browser.deinit();

    // 4. Launch TUI
    var app_tui = try tui.Tui.init(allocator);

    // Initial render
    try ui.render(app_tui, browser, config, true);
    try app_tui.flush();

    run(allocator, config, browser, &app_tui) catch |err| {
        app_tui.deinit();
        return err;
    };

    const final_path = try allocator.dupe(u8, browser.path);
    defer allocator.free(final_path);

    app_tui.deinit();

    if (!std.mem.eql(u8, final_path, cwd)) {
        const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
        const shell_z = try allocator.dupeZ(u8, shell);
        defer allocator.free(shell_z);
        const argv = &[_:null]?[*:0]const u8{ shell_z.ptr, null };
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

fn run(allocator: std.mem.Allocator, config: *Config, browser: *Browser, app_tui_ptr: **tui.Tui) !void {
    var full_redraw = false;

    var last_blink_instant = try std.time.Instant.now();

    while (true) {
        var timeout: i32 = -1;

        if (browser.is_editing or browser.prompt_mode != .none) {
            const now = try std.time.Instant.now();
            const blink_ms: i32 = 500;
            const elapsed_since_blink = @divTrunc(now.since(last_blink_instant), std.time.ns_per_ms);
            timeout = @max(@as(i32, 0), blink_ms - @as(i32, @intCast(elapsed_since_blink)));
        }

        var fds = [_]std.posix.pollfd{
            .{ .fd = app_tui_ptr.*.stdin.handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = browser.inotify_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };

        const ready = try std.posix.poll(&fds, timeout);

        var fs_event = false;
        var config_event = false;
        var key_pressed = false;
        var blink_event = false;

        if (ready == 0 and (browser.is_editing or browser.prompt_mode != .none)) {
            blink_event = true;
            browser.is_cursor_visible = !browser.is_cursor_visible;
            last_blink_instant = try std.time.Instant.now();
        } else {
            if (fds[1].revents & std.posix.POLL.IN != 0) {
                var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
                const n = try std.posix.read(browser.inotify_fd, &buf);

                var i: usize = 0;
                while (i < n) {
                    const event: *std.os.linux.inotify_event = @ptrCast(@alignCast(&buf[i]));
                    if (event.wd == browser.cwd_wd) fs_event = true;
                    if (event.wd == browser.config_wd) config_event = true;
                    i += @sizeOf(std.os.linux.inotify_event) + event.len;
                }
            }

            if (fds[0].revents & std.posix.POLL.IN != 0) {
                const key_raw = try app_tui_ptr.*.pollKey(0);
                if (key_raw) |kr| {
                    key_pressed = true;
                    browser.is_cursor_visible = true;
                    last_blink_instant = try std.time.Instant.now();

                    // Clear error on any key press
                    if (browser.error_message != null) {
                        browser.clearError();
                        full_redraw = true;
                    }

                    const key: tui.Key = @enumFromInt(kr);
                    if (key == .ctrl_c or (key == @as(tui.Key, @enumFromInt('q')) and !browser.is_editing and browser.prompt_mode == .none)) break;

                    if (browser.prompt_mode != .none) {
                        switch (key) {
                            .esc, .ctrl_g => try browser.stopPrompt(false),
                            .ret => try browser.stopPrompt(true),
                            .left, .ctrl_b => browser.moveCharBackward(),
                            .right, .ctrl_f => browser.moveCharForward(),
                            .ctrl_a => browser.moveLineStart(),
                            .ctrl_e => browser.moveLineEnd(),
                            .backspace => try browser.backspace(),
                            .ctrl_d => try browser.deleteCharUnderCursor(),
                            .ctrl_k => try browser.killLine(),
                            .ctrl_y => try browser.yank(),
                            else => if (kr >= 32 and kr < 0x1000) try browser.insertChar(@intCast(kr)),
                        }
                        full_redraw = true;
                    } else if (browser.is_editing) {
                        switch (key) {
                            .esc, .ctrl_g => try browser.stopEditing(true),
                            .up, .ctrl_p => {
                                try browser.stopEditing(true);
                                browser.moveUp();
                            },
                            .down, .ctrl_n => {
                                try browser.stopEditing(true);
                                browser.moveDown();
                            },
                            .left, .ctrl_b => browser.moveCharBackward(),
                            .right, .ctrl_f => browser.moveCharForward(),
                            .ctrl_a => browser.moveLineStart(),
                            .ctrl_e => browser.moveLineEnd(),
                            .ctrl_k => try browser.killLine(),
                            .ctrl_y => try browser.yank(),
                            .meta_d => try browser.killWord(),
                            .backspace => try browser.backspace(),
                            .ctrl_d => try browser.deleteCharUnderCursor(),
                            .ret => try browser.stopEditing(true),
                            else => if (kr >= 32 and kr < 0x1000) try browser.insertChar(@intCast(kr)),
                        }
                        full_redraw = true;
                    } else {
                        if (key == @as(tui.Key, @enumFromInt('j')) or key == @as(tui.Key, @enumFromInt('n')) or key == .ctrl_n or key == .down) {
                            browser.moveDown();
                        } else if (key == @as(tui.Key, @enumFromInt('k')) or key == @as(tui.Key, @enumFromInt('p')) or key == .ctrl_p or key == .up) {
                            browser.moveUp();
                        } else if (key == .g) {
                            browser.moveTop();
                        } else if (key == .G) {
                            browser.moveBottom();
                        } else if (key == @as(tui.Key, @enumFromInt('h'))) {
                            try browser.cdUp();
                            full_redraw = true;
                        } else if (key == .tab) {
                            try browser.toggleExpand();
                            full_redraw = true;
                        } else if (key == @as(tui.Key, @enumFromInt('l')) or key == .ret) {
                            const action = try browser.openSelected();
                            switch (action) {
                                .none => full_redraw = true,
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
                        } else if (key == @as(tui.Key, @enumFromInt('f'))) {
                            try browser.startPrompt(.create_file);
                            full_redraw = true;
                        } else if (key == @as(tui.Key, @enumFromInt('+'))) {
                            try browser.startPrompt(.create_dir);
                            full_redraw = true;
                        } else if (key == .backspace) {
                            try browser.startEditing();
                            try browser.backspace();
                        } else if (key == .ctrl_d) {
                            try browser.startEditing();
                            try browser.deleteCharUnderCursor();
                        } else if (key == .ctrl_k) {
                            try browser.killLine();
                        } else if (key == .ctrl_y) {
                            try browser.yank();
                        } else if (key == .meta_d) {
                            try browser.killWord();
                        }
                    }
                }
            }
        }

        if (config_event) {
            config.reload() catch {};
            try browser.refresh(null);
            full_redraw = true;
        }

        if (fs_event) {
            try browser.refresh(null);
            full_redraw = true;
        }

        if (full_redraw or key_pressed or fs_event or config_event or blink_event) {
            try ui.render(app_tui_ptr.*, browser, config, full_redraw);
            try app_tui_ptr.*.flush();
            full_redraw = false;
        }
    }
}
