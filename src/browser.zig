const std = @import("std");
const Config = @import("config.zig").Config;

pub const FileEntry = struct {
    name:         []const u8,
    full_path:    []const u8,
    is_dir:       bool,
    is_expanded:  bool = false,
    level:        usize = 0,
    mode:         u64,
    nlink:        u64,
    size:         u64,
    mtime:        i128,
    
    // Cached render data
    perm_str:     [10]u8 = undefined,
    size_str:     []const u8 = "",
    date_str:     [12]u8 = undefined,
    
    allocator:    std.mem.Allocator,

    pub fn deinit(self: *FileEntry) void {
        self.allocator.free(self.name);
        self.allocator.free(self.full_path);
        if (self.size_str.len > 0) self.allocator.free(self.size_str);
    }
};

pub const PromptMode = enum {
    none,
    create_file,
    create_dir,
};

pub const Browser = struct {
    path:           []const u8,
    entries:        std.ArrayList(FileEntry),
    selected_index: usize = 0,
    prev_index:     ?usize = null,
    scroll_offset:  usize = 0,
    char_offset:    usize = 0,
    allocator:      std.mem.Allocator,
    max_size_len:   usize = 1,
    
    // Editing state
    is_editing:     bool = false,
    edit_buffer:    std.ArrayList(u8),
    is_cursor_visible: bool = true,
    kill_ring:      std.ArrayList(u8),

    // Prompt state
    prompt_mode:    PromptMode = .none,
    prompt_buffer:  std.ArrayList(u8),
    prompt_parent_path: ?[]const u8 = null,

    // Error state
    error_message:  ?[]const u8 = null,

    // Path -> Selected Index history
    cursor_history: std.StringHashMap(usize),
    // Full Path -> Expanded state
    expansion_history: std.StringHashMap(void),
    
    // Inotify management
    inotify_fd:     i32 = -1,
    cwd_wd:         i32 = -1,
    config_wd:      i32 = -1,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !*Browser {
        const browser = try allocator.create(Browser);
        browser.* = .{
            .path = try allocator.dupe(u8, path),
            .entries = try std.ArrayList(FileEntry).initCapacity(allocator, 64),
            .allocator = allocator,
            .edit_buffer = try std.ArrayList(u8).initCapacity(allocator, 64),
            .kill_ring = try std.ArrayList(u8).initCapacity(allocator, 64),
            .prompt_buffer = try std.ArrayList(u8).initCapacity(allocator, 64),
            .cursor_history = std.StringHashMap(usize).init(allocator),
            .expansion_history = std.StringHashMap(void).init(allocator),
        };
        
        // Setup inotify
        browser.inotify_fd = std.posix.inotify_init1(std.os.linux.IN.CLOEXEC | std.os.linux.IN.NONBLOCK) catch -1;
        
        // Watch config
        if (std.posix.getenv("HOME")) |home| {
            var p_buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&p_buf);
            const config_dir = std.fs.path.join(fba.allocator(), &.{ home, ".config", "direx" }) catch null;
            if (config_dir) |dir| {
                if (browser.inotify_fd != -1) {
                    browser.config_wd = std.posix.inotify_add_watch(browser.inotify_fd, dir, std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE) catch -1;
                }
            }
        }
        
        try browser.updateCwdWatch();
        try browser.refresh(null);
        return browser;
    }

    pub fn deinit(self: *Browser) void {
        if (self.inotify_fd != -1) std.posix.close(self.inotify_fd);
        self.allocator.free(self.path);
        for (self.entries.items) |*entry| {
            entry.deinit();
        }
        self.entries.deinit(self.allocator);
        self.edit_buffer.deinit(self.allocator);
        self.kill_ring.deinit(self.allocator);
        self.prompt_buffer.deinit(self.allocator);
        if (self.prompt_parent_path) |p| self.allocator.free(p);
        if (self.error_message) |msg| self.allocator.free(msg);
        
        var c_iter = self.cursor_history.iterator();
        while (c_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.cursor_history.deinit();

        var e_iter = self.expansion_history.iterator();
        while (e_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.expansion_history.deinit();
        
        self.allocator.destroy(self);
    }

    fn updateCwdWatch(self: *Browser) !void {
        if (self.inotify_fd == -1) return;
        if (self.cwd_wd != -1) {
            std.posix.inotify_rm_watch(self.inotify_fd, self.cwd_wd);
        }
        self.cwd_wd = std.posix.inotify_add_watch(self.inotify_fd, self.path, 
            std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE | std.os.linux.IN.DELETE | std.os.linux.IN.MOVED_FROM | std.os.linux.IN.MOVED_TO) catch -1;
    }

    fn statNoFollow(dir: std.fs.Dir, io: std.Io, sub_path: []const u8) !std.fs.File.Stat {
        return std.Io.Dir.statPath(.{ .handle = dir.fd }, io, sub_path, .{ .follow_symlinks = false });
    }

    pub fn setError(self: *Browser, msg: []const u8) void {
        if (self.error_message) |old| self.allocator.free(old);
        self.error_message = self.allocator.dupe(u8, msg) catch null;
    }

    pub fn clearError(self: *Browser) void {
        if (self.error_message) |msg| {
            self.allocator.free(msg);
            self.error_message = null;
        }
    }

    pub fn refresh(self: *Browser, target_full_path: ?[]const u8) !void {
        for (self.entries.items) |*entry| entry.deinit();
        self.entries.clearRetainingCapacity();
        self.prev_index = null;
        if (!self.is_editing and self.prompt_mode == .none) self.char_offset = 0;

        var dir = std.fs.cwd().openDir(self.path, .{ .iterate = true }) catch return;
        defer dir.close();

        var threaded: std.Io.Threaded = .init_single_threaded;
        const io = threaded.ioBasic();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const stat = statNoFollow(dir, io, entry.name) catch continue;
            const full_path = try std.fs.path.join(self.allocator, &.{ self.path, entry.name });
            
            var fe = FileEntry{
                .name        = try self.allocator.dupe(u8, entry.name),
                .full_path   = full_path,
                .is_dir      = entry.kind == .directory,
                .mode        = stat.mode,
                .nlink       = 1,
                .size        = stat.size,
                .mtime       = stat.mtime.nanoseconds,
                .allocator   = self.allocator,
            };
            
            fe.perm_str = formatPermissions(fe.mode, fe.is_dir);
            fe.date_str = formatDate(fe.mtime);
            var buf: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{stat.size});
            fe.size_str = try self.allocator.dupe(u8, s);
            if (s.len > self.max_size_len) self.max_size_len = s.len;
            
            try self.entries.append(self.allocator, fe);
        }

        std.mem.sort(FileEntry, self.entries.items, {}, sortEntries);

        // Re-expand entries based on history
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = &self.entries.items[i];
            if (entry.is_dir and self.expansion_history.contains(entry.full_path)) {
                try self.expandEntryAtIndex(io, i);
            }
            i += 1;
        }

        // Restore selection
        var found_target = false;
        if (target_full_path) |target| {
            for (self.entries.items, 0..) |entry, idx| {
                if (std.mem.eql(u8, entry.full_path, target)) {
                    self.selected_index = idx;
                    found_target = true;
                    break;
                }
            }
        }

        if (!found_target) {
            if (self.cursor_history.get(self.path)) |idx| {
                self.selected_index = if (idx < self.entries.items.len) idx else 0;
            } else {
                self.selected_index = 0;
            }
        }
        
        try self.saveCurrentIndex();
    }

    pub fn saveCurrentIndex(self: *Browser) !void {
        const gop = try self.cursor_history.getOrPut(self.path);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, self.path);
        }
        gop.value_ptr.* = self.selected_index;
    }

    pub fn manageScroll(self: *Browser, viewport_h: u16) bool {
        if (viewport_h == 0) return false;
        const h = @as(usize, viewport_h);
        const old_offset = self.scroll_offset;

        if (self.selected_index < self.scroll_offset or self.selected_index >= self.scroll_offset + h) {
            if (self.selected_index < h / 2) {
                self.scroll_offset = 0;
            } else {
                self.scroll_offset = self.selected_index - (h / 2);
            }
        }

        if (self.entries.items.len <= h) {
            self.scroll_offset = 0;
        } else if (self.scroll_offset + h > self.entries.items.len) {
            self.scroll_offset = self.entries.items.len - h;
        }

        return old_offset != self.scroll_offset;
    }

    fn formatPermissions(mode: u64, is_dir: bool) [10]u8 {
        var buf: [10]u8 = undefined;
        buf[0] = if (is_dir) 'd' else '-';
        const chars = "rwxrwxrwx";
        for (0..9) |pi| {
            const bit = @as(u64, 1) << @as(u6, @intCast(8 - pi));
            buf[pi+1] = if ((mode & bit) != 0) chars[pi] else '-';
        }
        return buf;
    }

    fn formatDate(mtime_ns: i128) [12]u8 {
        const seconds = @as(u64, @intCast(@divTrunc(mtime_ns, std.time.ns_per_s)));
        const epoch_secs = std.time.epoch.EpochSeconds{ .secs = seconds };
        const epoch_day = epoch_secs.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_secs = epoch_secs.getDaySeconds();
        
        const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
        const month = month_names[month_day.month.numeric() - 1];
        
        var buf: [12]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{s} {d:>2} {d:0>2}:{d:0>2}", .{ 
            month, 
            month_day.day_index + 1, 
            day_secs.getHoursIntoDay(), 
            day_secs.getMinutesIntoHour() 
        }) catch {
            @memset(&buf, ' ');
        };
        return buf;
    }

    fn sortEntries(_: void, a: FileEntry, b: FileEntry) bool {
        const name_a = if (a.name.len > 0 and a.name[0] == '.') a.name[1..] else a.name;
        const name_b = if (b.name.len > 0 and b.name[0] == '.') b.name[1..] else b.name;
        const len = @min(name_a.len, name_b.len);
        for (0..len) |i| {
            const ca = std.ascii.toLower(name_a[i]);
            const cb = std.ascii.toLower(name_b[i]);
            if (ca != cb) return ca < cb;
        }
        return name_a.len < name_b.len;
    }

    pub fn moveUp(self: *Browser) void {
        if (self.entries.items.len == 0) return;
        self.prev_index = self.selected_index;
        self.selected_index = if (self.selected_index == 0) self.entries.items.len - 1 else self.selected_index - 1;
        self.char_offset = 0;
        self.saveCurrentIndex() catch {};
    }

    pub fn moveDown(self: *Browser) void {
        if (self.entries.items.len == 0) return;
        self.prev_index = self.selected_index;
        self.selected_index = if (self.selected_index == self.entries.items.len - 1) 0 else self.selected_index + 1;
        self.char_offset = 0;
        self.saveCurrentIndex() catch {};
    }
    
    pub fn moveTop(self: *Browser) void {
        if (self.entries.items.len == 0) return;
        self.prev_index = self.selected_index;
        self.selected_index = 0;
        self.char_offset = 0;
        self.saveCurrentIndex() catch {};
    }

    pub fn moveBottom(self: *Browser) void {
        if (self.entries.items.len == 0) return;
        self.prev_index = self.selected_index;
        self.selected_index = self.entries.items.len - 1;
        self.char_offset = 0;
        self.saveCurrentIndex() catch {};
    }

    pub fn moveCharForward(self: *Browser) void {
        const buf_items = if (self.prompt_mode != .none) self.prompt_buffer.items else if (self.is_editing) self.edit_buffer.items else if (self.entries.items.len > 0) self.entries.items[self.selected_index].name else return;
        const count = std.unicode.utf8CountCodepoints(buf_items) catch return;
        if (self.char_offset < count) {
            self.char_offset += 1;
        }
    }

    pub fn moveCharBackward(self: *Browser) void {
        if (self.char_offset > 0) {
            self.char_offset -= 1;
        }
    }

    pub fn moveLineStart(self: *Browser) void {
        self.char_offset = 0;
    }

    pub fn moveLineEnd(self: *Browser) void {
        const buf_items = if (self.prompt_mode != .none) self.prompt_buffer.items else if (self.is_editing) self.edit_buffer.items else if (self.entries.items.len > 0) self.entries.items[self.selected_index].name else return;
        const count = std.unicode.utf8CountCodepoints(buf_items) catch return;
        self.char_offset = count;
    }

    pub fn startEditing(self: *Browser) !void {
        if (self.entries.items.len == 0) return;
        self.is_editing = true;
        self.edit_buffer.clearRetainingCapacity();
        try self.edit_buffer.appendSlice(self.allocator, self.entries.items[self.selected_index].name);
    }

    pub fn stopEditing(self: *Browser, apply: bool) !void {
        if (!self.is_editing) return;
        if (apply) {
            self.renameSelected(self.edit_buffer.items) catch |err| {
                self.setError(@errorName(err));
            };
        }
        self.is_editing = false;
        self.edit_buffer.clearRetainingCapacity();
    }

    pub fn startPrompt(self: *Browser, mode: PromptMode) !void {
        self.prompt_mode = mode;
        self.prompt_buffer.clearRetainingCapacity();
        self.char_offset = 0;

        if (self.prompt_parent_path) |p| self.allocator.free(p);
        
        if (self.entries.items.len > 0) {
            const entry = self.entries.items[self.selected_index];
            if (entry.is_dir and entry.is_expanded) {
                self.prompt_parent_path = try self.allocator.dupe(u8, entry.full_path);
            } else {
                const dir = std.fs.path.dirname(entry.full_path) orelse self.path;
                self.prompt_parent_path = try self.allocator.dupe(u8, dir);
            }
        } else {
            self.prompt_parent_path = try self.allocator.dupe(u8, self.path);
        }
    }

    pub fn stopPrompt(self: *Browser, apply: bool) !void {
        if (self.prompt_mode == .none) return;
        if (apply and self.prompt_buffer.items.len > 0) {
            const name = self.prompt_buffer.items;
            const parent = self.prompt_parent_path orelse self.path;
            const full_path = try std.fs.path.join(self.allocator, &.{ parent, name });
            defer self.allocator.free(full_path);
            
            const create_result = if (self.prompt_mode == .create_file) blk: {
                const file = std.fs.createFileAbsolute(full_path, .{}) catch |err| break :blk err;
                file.close();
                break :blk {};
            } else if (self.prompt_mode == .create_dir) blk: {
                break :blk std.fs.makeDirAbsolute(full_path);
            } else unreachable;

            if (create_result) |_| {
                try self.refresh(full_path);
            } else |err| {
                self.setError(@errorName(err));
            }
        }
        self.prompt_mode = .none;
        self.prompt_buffer.clearRetainingCapacity();
        self.char_offset = 0;
    }

    pub fn renameSelected(self: *Browser, new_name: []const u8) !void {
        if (self.entries.items.len == 0) return;
        const entry = &self.entries.items[self.selected_index];
        if (std.mem.eql(u8, entry.name, new_name)) return;

        const parent_path = std.fs.path.dirname(entry.full_path) orelse return;
        const new_full_path = try std.fs.path.join(self.allocator, &.{ parent_path, new_name });
        defer self.allocator.free(new_full_path);

        try std.fs.renameAbsolute(entry.full_path, new_full_path);
        
        if (entry.is_dir and self.expansion_history.contains(entry.full_path)) {
            if (self.expansion_history.fetchRemove(entry.full_path)) |old| {
                self.allocator.free(old.key);
            }
            try self.expansion_history.put(try self.allocator.dupe(u8, new_full_path), {});
        }

        try self.refresh(new_full_path);
    }

    pub fn deleteCharUnderCursor(self: *Browser) !void {
        const active_buffer = if (self.prompt_mode != .none) &self.prompt_buffer else if (self.is_editing) &self.edit_buffer else null;
        if (active_buffer == null) {
            if (self.entries.items.len == 0) return;
            try self.startEditing();
            return self.deleteCharUnderCursor();
        }

        var iter = (std.unicode.Utf8View.init(active_buffer.?.items) catch return).iterator();
        var i: usize = 0;
        while (i < self.char_offset) : (i += 1) _ = iter.nextCodepoint();
        
        const start = iter.i;
        if (iter.nextCodepoint()) |_| {
            const end = iter.i;
            const deleted = active_buffer.?.items[start..end];
            if (self.is_editing) {
                self.kill_ring.clearRetainingCapacity();
                try self.kill_ring.appendSlice(self.allocator, deleted);
            }
            active_buffer.?.replaceRange(self.allocator, start, end - start, &.{}) catch {};
        }
    }

    pub fn backspace(self: *Browser) !void {
        if (self.char_offset == 0) {
            if (self.prompt_mode == .none and !self.is_editing and self.entries.items.len > 0) try self.startEditing();
            return;
        }
        if (self.prompt_mode == .none and !self.is_editing and self.entries.items.len > 0) try self.startEditing();

        self.char_offset -= 1;
        try self.deleteCharUnderCursor();
    }

    pub fn killLine(self: *Browser) !void {
        if (self.entries.items.len == 0) return;
        const name = if (self.is_editing) self.edit_buffer.items else self.entries.items[self.selected_index].name;
        
        var iter = (std.unicode.Utf8View.init(name) catch return).iterator();
        var i: usize = 0;
        while (i < self.char_offset) : (i += 1) _ = iter.nextCodepoint();
        
        const start = iter.i;
        const killed = name[start..];
        
        if (killed.len > 0) {
            self.kill_ring.clearRetainingCapacity();
            try self.kill_ring.appendSlice(self.allocator, killed);
        }

        if (self.is_editing) {
            try self.edit_buffer.resize(self.allocator, start);
        } else {
            self.char_offset = std.unicode.utf8CountCodepoints(name) catch self.char_offset;
            self.kill_ring.clearRetainingCapacity();
            try self.kill_ring.appendSlice(self.allocator, killed);
        }
    }

    pub fn killWord(self: *Browser) !void {
        if (self.entries.items.len == 0) return;
        if (!self.is_editing) try self.startEditing();

        const name = self.edit_buffer.items;
        var iter = (std.unicode.Utf8View.init(name) catch return).iterator();
        var i: usize = 0;
        while (i < self.char_offset) : (i += 1) _ = iter.nextCodepoint();
        const start = iter.i;

        while (true) {
            const prev_i = iter.i;
            if (iter.nextCodepoint()) |cp| {
                if (std.ascii.isAlphanumeric(@intCast(cp))) {
                    iter.i = prev_i;
                    break;
                }
            } else break;
        }

        while (true) {
            const prev_i = iter.i;
            if (iter.nextCodepoint()) |cp| {
                if (!std.ascii.isAlphanumeric(@intCast(cp))) {
                    iter.i = prev_i;
                    break;
                }
            } else break;
        }
        
        const end = iter.i;
        const killed = name[start..end];
        if (killed.len > 0) {
            self.kill_ring.clearRetainingCapacity();
            try self.kill_ring.appendSlice(self.allocator, killed);
            self.edit_buffer.replaceRange(self.allocator, start, end - start, &.{}) catch {};
        }
    }

    pub fn yank(self: *Browser) !void {
        if (self.kill_ring.items.len == 0) return;
        const active_buffer = if (self.prompt_mode != .none) &self.prompt_buffer else if (self.is_editing) &self.edit_buffer else null;
        if (active_buffer == null) {
            if (self.entries.items.len == 0) return;
            try self.startEditing();
            return self.yank();
        }

        var iter = (std.unicode.Utf8View.init(active_buffer.?.items) catch return).iterator();
        var i: usize = 0;
        while (i < self.char_offset) : (i += 1) _ = iter.nextCodepoint();
        
        try active_buffer.?.insertSlice(self.allocator, iter.i, self.kill_ring.items);
        self.char_offset += std.unicode.utf8CountCodepoints(self.kill_ring.items) catch 0;
    }

    pub fn insertChar(self: *Browser, cp: u21) !void {
        const active_buffer = if (self.prompt_mode != .none) &self.prompt_buffer else if (self.is_editing) &self.edit_buffer else null;
        if (active_buffer == null) {
            if (self.entries.items.len == 0) return;
            try self.startEditing();
            return self.insertChar(cp);
        }

        var utf8_buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &utf8_buf);
        
        var iter = (std.unicode.Utf8View.init(active_buffer.?.items) catch return).iterator();
        var i: usize = 0;
        while (i < self.char_offset) : (i += 1) _ = iter.nextCodepoint();
        
        try active_buffer.?.insertSlice(self.allocator, iter.i, utf8_buf[0..len]);
        self.char_offset += 1;
    }

    pub fn cdUp(self: *Browser) !void {
        try self.saveCurrentIndex();
        const old_path = try self.allocator.dupe(u8, self.path);
        defer self.allocator.free(old_path);
        const parent = std.fs.path.dirname(self.path) orelse return;
        const new_path = try self.allocator.dupe(u8, parent);
        self.allocator.free(self.path);
        self.path = new_path;
        self.max_size_len = 1;
        try self.updateCwdWatch();
        try self.refresh(old_path);
    }

    pub fn toggleExpand(self: *Browser) !void {
        if (self.entries.items.len == 0) return;
        const idx = self.selected_index;
        var entry = &self.entries.items[idx];
        if (!entry.is_dir) return;

        if (entry.is_expanded) {
            if (self.expansion_history.fetchRemove(entry.full_path)) |old| {
                self.allocator.free(old.key);
            }
            entry.is_expanded = false;
            const current_level = entry.level;
            var end_idx = idx + 1;
            while (end_idx < self.entries.items.len and self.entries.items[end_idx].level > current_level) : (end_idx += 1) {}
            const remove_count = end_idx - (idx + 1);
            if (remove_count > 0) {
                for (self.entries.items[idx+1..end_idx]) |*e| e.deinit();
                self.entries.replaceRange(self.allocator, idx + 1, remove_count, &.{}) catch {};
            }
        } else {
            const path_key = try self.allocator.dupe(u8, entry.full_path);
            if (try self.expansion_history.fetchPut(path_key, {})) |old| {
                self.allocator.free(old.key);
            }

            var threaded: std.Io.Threaded = .init_single_threaded;
            const io = threaded.ioBasic();
            try self.recursiveExpand(io, idx);
        }
        try self.saveCurrentIndex();
    }

    fn recursiveExpand(self: *Browser, io: std.Io, start_idx: usize) !void {
        try self.expandEntryAtIndex(io, start_idx);
        var i = start_idx + 1;
        const parent_level = self.entries.items[start_idx].level;
        while (i < self.entries.items.len) {
            const entry = &self.entries.items[i];
            if (entry.level <= parent_level) break;
            if (entry.is_dir and self.expansion_history.contains(entry.full_path)) {
                try self.expandEntryAtIndex(io, i);
            }
            i += 1;
        }
    }

    fn expandEntryAtIndex(self: *Browser, io: std.Io, idx: usize) !void {
        var entry = &self.entries.items[idx];
        entry.is_expanded = true;
        const current_level = entry.level;
        const parent_path = entry.full_path;

        var dir = std.fs.openDirAbsolute(parent_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        var new_entries = try std.ArrayList(FileEntry).initCapacity(self.allocator, 16);
        defer new_entries.deinit(self.allocator);

        while (try iter.next()) |e| {
            const stat = statNoFollow(dir, io, e.name) catch continue;
            const full_path = try std.fs.path.join(self.allocator, &.{ parent_path, e.name });
            var fe = FileEntry{
                .name        = try self.allocator.dupe(u8, e.name),
                .full_path   = full_path,
                .is_dir      = e.kind == .directory,
                .level       = current_level + 1,
                .mode        = stat.mode,
                .nlink       = 1,
                .size        = stat.size,
                .mtime       = stat.mtime.nanoseconds,
                .allocator   = self.allocator,
            };
            fe.perm_str = formatPermissions(fe.mode, fe.is_dir);
            fe.date_str = formatDate(fe.mtime);
            var buf: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{stat.size});
            fe.size_str = try self.allocator.dupe(u8, s);
            if (s.len > self.max_size_len) self.max_size_len = s.len;
            try new_entries.append(self.allocator, fe);
        }
        std.mem.sort(FileEntry, new_entries.items, {}, sortEntries);
        try self.entries.insertSlice(self.allocator, idx + 1, new_entries.items);
    }

    pub fn openSelected(self: *Browser) !union(enum) { none, editor: []const u8 } {
        if (self.entries.items.len == 0) return .none;
        const entry = self.entries.items[self.selected_index];
        if (entry.is_dir) {
            try self.saveCurrentIndex();
            self.allocator.free(self.path);
            self.path = try self.allocator.dupe(u8, entry.full_path);
            self.max_size_len = 1;
            try self.updateCwdWatch();
            try self.refresh(null);
            return .none;
        } else {
            return .{ .editor = try self.allocator.dupe(u8, entry.full_path) };
        }
    }
};
