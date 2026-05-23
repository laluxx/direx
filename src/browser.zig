const std = @import("std");
const Config = @import("config.zig").Config;

pub const FileEntry = struct {
    name:      []const u8,
    is_dir:    bool,
    mode:      u64,
    nlink:     u64,
    uid:       u32,
    gid:       u32,
    size:      u64,
    mtime:     i128,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FileEntry) void {
        self.allocator.free(self.name);
    }
};

pub const Browser = struct {
    path:           []const u8,
    entries:        std.ArrayList(FileEntry),
    selected_index: usize = 0,
    allocator:      std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !*Browser {
        const browser = try allocator.create(Browser);
        browser.* = .{
            .path = try allocator.dupe(u8, path),
            .entries = try std.ArrayList(FileEntry).initCapacity(allocator, 0),
            .allocator = allocator,
        };
        try browser.refresh();
        return browser;
    }

    pub fn deinit(self: *Browser) void {
        self.allocator.free(self.path);
        for (self.entries.items) |*entry| {
            entry.deinit();
        }
        self.entries.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn refresh(self: *Browser) !void {
        for (self.entries.items) |*entry| {
            entry.deinit();
        }
        self.entries.clearRetainingCapacity();

        var dir = try std.fs.cwd().openDir(self.path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const stat = try dir.statFile(entry.name);
            try self.entries.append(self.allocator, .{
                .name      = try self.allocator.dupe(u8, entry.name),
                .is_dir    = entry.kind == .directory,
                .mode      = stat.mode,
                .nlink     = 1,    // std.fs.File.Stat doesn't seem to have nlink in all OSes, but let's assume 1 for now or find a way.
                .uid       = 1000, // Placeholder
                .gid       = 1000, // Placeholder
                .size      = stat.size,
                .mtime     = stat.mtime.nanoseconds,
                .allocator = self.allocator,
            });
        }

        // Sort entries: directories first, then alphabetical
        std.mem.sort(FileEntry, self.entries.items, {}, sortEntries);

        if (self.selected_index >= self.entries.items.len and self.entries.items.len > 0) {
            self.selected_index = self.entries.items.len - 1;
        }
    }

    fn sortEntries(_: void, a: FileEntry, b: FileEntry) bool {
        if (a.is_dir != b.is_dir) {
            return a.is_dir;
        }
        return std.mem.lessThan(u8, a.name, b.name);
    }

    pub fn moveUp(self: *Browser) void {
        if (self.entries.items.len == 0) return;
        if (self.selected_index == 0) {
            self.selected_index = self.entries.items.len - 1;
        } else {
            self.selected_index -= 1;
        }
    }

    pub fn moveDown(self: *Browser) void {
        if (self.entries.items.len == 0) return;
        if (self.selected_index == self.entries.items.len - 1) {
            self.selected_index = 0;
        } else {
            self.selected_index += 1;
        }
    }

    pub fn cdUp(self: *Browser) !void {
        const parent = std.fs.path.dirname(self.path) orelse return;
        const new_path = try self.allocator.dupe(u8, parent);
        self.allocator.free(self.path);
        self.path = new_path;
        self.selected_index = 0;
        try self.refresh();
    }

    pub fn openSelected(self: *Browser) !union(enum) { none, editor: []const u8 } {
        if (self.entries.items.len == 0) return .none;
        const entry = self.entries.items[self.selected_index];
        const full_path = try std.fs.path.join(self.allocator, &.{ self.path, entry.name });
        defer self.allocator.free(full_path);

        if (entry.is_dir) {
            self.allocator.free(self.path);
            self.path = try self.allocator.dupe(u8, full_path);
            self.selected_index = 0;
            try self.refresh();
            return .none;
        } else {
            return .{ .editor = try self.allocator.dupe(u8, full_path) };
        }
    }
};
