//! Markdown-based memory — plain files as source of truth.
//!
//! Layout:
//!   workspace/MEMORY.md            — core memory
//!   workspace/memory/<category>.md — non-core categories
//!
//! Entries are stored as markdown bullets with inline metadata comments so the
//! backend can preserve exact `(key, session_id)` semantics while staying human
//! readable and easy to inspect.

const std = @import("std");
const fs_compat = @import("../../fs_compat.zig");
const root = @import("../root.zig");
const Memory = root.Memory;
const MemoryCategory = root.MemoryCategory;
const MemoryEntry = root.MemoryEntry;

pub const MarkdownMemory = struct {
    workspace_dir: []const u8,
    allocator: std.mem.Allocator,
    owns_self: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, workspace_dir: []const u8) !Self {
        return Self{
            .workspace_dir = try allocator.dupe(u8, workspace_dir),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.workspace_dir);
    }

    fn corePath(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{self.workspace_dir});
    }

    fn rootPath(self: *const Self, allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.workspace_dir, filename });
    }

    fn memoryDir(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/memory", .{self.workspace_dir});
    }

    fn categoryFileStem(allocator: std.mem.Allocator, category: MemoryCategory) ![]u8 {
        const raw = category.toString();
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);

        for (raw) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.') {
                try buf.append(allocator, ch);
            } else {
                try buf.append(allocator, '_');
            }
        }

        if (buf.items.len == 0) try buf.appendSlice(allocator, "custom");
        return buf.toOwnedSlice(allocator);
    }

    fn categoryPath(self: *const Self, allocator: std.mem.Allocator, category: MemoryCategory) ![]u8 {
        if (category.eql(.core)) return self.corePath(allocator);

        const stem = try categoryFileStem(allocator, category);
        defer allocator.free(stem);
        return std.fmt.allocPrint(allocator, "{s}/memory/{s}.md", .{ self.workspace_dir, stem });
    }

    fn ensureDir(path: []const u8) !void {
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }

    fn writeFileContents(path: []const u8, content: []const u8, allocator: std.mem.Allocator) !void {
        try ensureDir(path);
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true, .read = true });
        defer file.close();
        _ = allocator;
        try file.writeAll(content);
        if (content.len == 0 or content[content.len - 1] != '\n') {
            try file.writeAll("\n");
        }
    }

    const ParsedMeta = struct {
        category: MemoryCategory,
        session_id: ?[]u8 = null,

        fn deinit(self: ParsedMeta, allocator: std.mem.Allocator) void {
            if (self.session_id) |sid| allocator.free(sid);
            switch (self.category) {
                .custom => |name| allocator.free(name),
                else => {},
            }
        }
    };

    fn parseMetaComment(meta: []const u8, fallback_category: MemoryCategory, allocator: std.mem.Allocator) !ParsedMeta {
        var parsed = ParsedMeta{
            .category = switch (fallback_category) {
                .custom => |name| .{ .custom = try allocator.dupe(u8, name) },
                else => fallback_category,
            },
            .session_id = null,
        };
        errdefer parsed.deinit(allocator);

        var iter = std.mem.splitScalar(u8, meta, ';');
        while (iter.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const name = trimmed[0..eq];
            const value = trimmed[eq + 1 ..];

            if (std.mem.eql(u8, name, "category")) {
                switch (parsed.category) {
                    .custom => |existing| allocator.free(existing),
                    else => {},
                }
                const cat = MemoryCategory.fromString(value);
                parsed.category = switch (cat) {
                    .custom => |custom_name| .{ .custom = try allocator.dupe(u8, custom_name) },
                    else => cat,
                };
            } else if (std.mem.eql(u8, name, "session")) {
                if (parsed.session_id) |sid| allocator.free(sid);
                parsed.session_id = if (value.len > 0) try allocator.dupe(u8, value) else null;
            }
        }

        return parsed;
    }

    fn sameSession(entry_session: ?[]const u8, target_session: ?[]const u8) bool {
        if (entry_session == null and target_session == null) return true;
        if (entry_session == null or target_session == null) return false;
        return std.mem.eql(u8, entry_session.?, target_session.?);
    }

    fn serializeEntry(allocator: std.mem.Allocator, entry: MemoryEntry) ![]u8 {
        return std.fmt.allocPrint(allocator, "- **{s}**: {s} <!-- nullclaw:category={s};session={s} -->", .{
            entry.key,
            entry.content,
            entry.category.toString(),
            entry.session_id orelse "",
        });
    }

    fn clearManagedFiles(self: *Self, allocator: std.mem.Allocator) !void {
        const core = try self.corePath(allocator);
        defer allocator.free(core);
        std.fs.deleteFileAbsolute(core) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        const md = try self.memoryDir(allocator);
        defer allocator.free(md);
        if (std.fs.openDirAbsolute(md, .{ .iterate = true })) |*dir_handle| {
            var dir = dir_handle.*;
            defer dir.close();
            var it = dir.iterate();
            while (try it.next()) |entry| {
                if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
                const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ md, entry.name });
                defer allocator.free(path);
                std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            }
        } else |_| {}
    }

    fn writeEntries(self: *Self, entries: []const MemoryEntry, allocator: std.mem.Allocator) !void {
        const Group = struct {
            path: []u8,
            buffer: std.ArrayListUnmanaged(u8) = .empty,
        };

        var groups: std.ArrayListUnmanaged(Group) = .empty;
        defer {
            for (groups.items) |*group| {
                allocator.free(group.path);
                group.buffer.deinit(allocator);
            }
            groups.deinit(allocator);
        }

        try self.clearManagedFiles(allocator);
        if (entries.len == 0) return;

        for (entries) |entry| {
            const path = try self.categoryPath(allocator, entry.category);
            defer allocator.free(path);

            var found_index: ?usize = null;
            for (groups.items, 0..) |group, idx| {
                if (std.mem.eql(u8, group.path, path)) {
                    found_index = idx;
                    break;
                }
            }

            if (found_index == null) {
                try groups.append(allocator, .{
                    .path = try allocator.dupe(u8, path),
                });
                found_index = groups.items.len - 1;
            }

            const line = try serializeEntry(allocator, entry);
            defer allocator.free(line);

            var group = &groups.items[found_index.?];
            if (group.buffer.items.len > 0) try group.buffer.append(allocator, '\n');
            try group.buffer.appendSlice(allocator, line);
        }

        for (groups.items) |group| {
            try writeFileContents(group.path, group.buffer.items, allocator);
        }
    }

    fn parseEntries(text: []const u8, filename: []const u8, category: MemoryCategory, allocator: std.mem.Allocator) ![]MemoryEntry {
        var entries: std.ArrayList(MemoryEntry) = .empty;
        errdefer {
            for (entries.items) |*e| e.deinit(allocator);
            entries.deinit(allocator);
        }

        var line_idx: usize = 0;
        var iter = std.mem.splitScalar(u8, text, '\n');
        while (iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') {
                continue;
            }

            const clean = if (std.mem.startsWith(u8, trimmed, "- "))
                trimmed[2..]
            else
                trimmed;

            const metadata_prefix = "<!-- nullclaw:";
            const metadata_start = std.mem.indexOf(u8, clean, metadata_prefix);
            const content_part = if (metadata_start) |idx|
                std.mem.trimRight(u8, clean[0..idx], " \t")
            else
                clean;

            var parsed_meta = ParsedMeta{
                .category = switch (category) {
                    .custom => |name| .{ .custom = try allocator.dupe(u8, name) },
                    else => category,
                },
                .session_id = null,
            };
            errdefer parsed_meta.deinit(allocator);

            if (metadata_start) |idx| {
                const meta_with_suffix = clean[idx + metadata_prefix.len ..];
                if (std.mem.indexOf(u8, meta_with_suffix, "-->")) |end_idx| {
                    parsed_meta.deinit(allocator);
                    parsed_meta = try parseMetaComment(meta_with_suffix[0..end_idx], category, allocator);
                }
            }

            const id = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ filename, line_idx });
            errdefer allocator.free(id);
            const explicit_key = blk: {
                if (!std.mem.startsWith(u8, content_part, "**")) break :blk null;
                const rest = content_part[2..];
                const suffix = std.mem.indexOf(u8, rest, "**:") orelse break :blk null;
                if (suffix == 0) break :blk null;
                break :blk rest[0..suffix];
            };
            const value_slice = if (explicit_key != null)
                std.mem.trim(u8, content_part[(2 + explicit_key.?.len + 3)..], " \t")
            else
                content_part;

            const key = try allocator.dupe(u8, explicit_key orelse id);
            errdefer allocator.free(key);
            const content_dup = try allocator.dupe(u8, value_slice);
            errdefer allocator.free(content_dup);
            const timestamp = try allocator.dupe(u8, filename);
            errdefer allocator.free(timestamp);

            try entries.append(allocator, MemoryEntry{
                .id = id,
                .key = key,
                .content = content_dup,
                .category = parsed_meta.category,
                .timestamp = timestamp,
                .session_id = parsed_meta.session_id,
            });
            parsed_meta = .{ .category = .core, .session_id = null };

            line_idx += 1;
        }

        return entries.toOwnedSlice(allocator);
    }

    fn readAllEntries(self: *Self, allocator: std.mem.Allocator) ![]MemoryEntry {
        var all: std.ArrayList(MemoryEntry) = .empty;
        errdefer {
            for (all.items) |*e| e.deinit(allocator);
            all.deinit(allocator);
        }

        var seen_root_paths: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var key_it = seen_root_paths.keyIterator();
            while (key_it.next()) |key| allocator.free(key.*);
            seen_root_paths.deinit(allocator);
        }

        const root_candidates = [_]struct {
            filename: []const u8,
            label: []const u8,
        }{
            .{ .filename = "MEMORY.md", .label = "MEMORY" },
            .{ .filename = "memory.md", .label = "memory" },
        };

        for (root_candidates) |candidate| {
            const root_path = try self.rootPath(allocator, candidate.filename);
            defer allocator.free(root_path);

            const content = fs_compat.readFileAlloc(std.fs.cwd(), allocator, root_path, 1024 * 1024) catch continue;
            defer allocator.free(content);

            const canonical = std.fs.realpathAlloc(allocator, root_path) catch
                try allocator.dupe(u8, root_path);
            errdefer allocator.free(canonical);
            if (seen_root_paths.contains(canonical)) {
                allocator.free(canonical);
                continue;
            }
            try seen_root_paths.put(allocator, canonical, {});

            const entries = try parseEntries(content, candidate.label, .core, allocator);
            defer allocator.free(entries);
            for (entries) |e| try all.append(allocator, e);
        }

        const md = try self.memoryDir(allocator);
        defer allocator.free(md);
        if (std.fs.cwd().openDir(md, .{ .iterate = true })) |*dir_handle| {
            var dir = dir_handle.*;
            defer dir.close();
            var it = dir.iterate();
            while (try it.next()) |entry| {
                if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
                const fpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ md, entry.name });
                defer allocator.free(fpath);
                if (fs_compat.readFileAlloc(std.fs.cwd(), allocator, fpath, 1024 * 1024)) |content| {
                    defer allocator.free(content);
                    const fname = entry.name[0 .. entry.name.len - 3];
                    const inferred_category = MemoryCategory.fromString(fname);
                    const entries = try parseEntries(content, fname, inferred_category, allocator);
                    defer allocator.free(entries);
                    for (entries) |e| try all.append(allocator, e);
                } else |_| {}
            }
        } else |_| {}

        return all.toOwnedSlice(allocator);
    }

    // ── Memory vtable impl ────────────────────────────────────────

    fn implName(_: *anyopaque) []const u8 {
        return "markdown";
    }

    fn implStore(ptr: *anyopaque, key: []const u8, content: []const u8, category: MemoryCategory, session_id: ?[]const u8) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        var entries = try self_.readAllEntries(self_.allocator);
        defer root.freeEntries(self_.allocator, entries);

        var updated = false;
        for (entries) |*entry| {
            if (!std.mem.eql(u8, entry.key, key)) continue;
            if (!sameSession(entry.session_id, session_id)) continue;

            self_.allocator.free(entry.content);
            entry.content = try self_.allocator.dupe(u8, content);
            self_.allocator.free(entry.timestamp);
            entry.timestamp = try std.fmt.allocPrint(self_.allocator, "{d}", .{std.time.timestamp()});
            if (entry.session_id) |sid| self_.allocator.free(sid);
            entry.session_id = if (session_id) |sid| try self_.allocator.dupe(u8, sid) else null;
            switch (entry.category) {
                .custom => |name| self_.allocator.free(name),
                else => {},
            }
            entry.category = switch (category) {
                .custom => |name| .{ .custom = try self_.allocator.dupe(u8, name) },
                else => category,
            };
            updated = true;
            break;
        }

        if (!updated) {
            const id = try std.fmt.allocPrint(self_.allocator, "md:{d}", .{std.time.nanoTimestamp()});
            errdefer self_.allocator.free(id);
            const stored_key = try self_.allocator.dupe(u8, key);
            errdefer self_.allocator.free(stored_key);
            const stored_content = try self_.allocator.dupe(u8, content);
            errdefer self_.allocator.free(stored_content);
            const timestamp = try std.fmt.allocPrint(self_.allocator, "{d}", .{std.time.timestamp()});
            errdefer self_.allocator.free(timestamp);
            const stored_category: MemoryCategory = switch (category) {
                .custom => |name| .{ .custom = try self_.allocator.dupe(u8, name) },
                else => category,
            };
            errdefer switch (stored_category) {
                .custom => |name| self_.allocator.free(name),
                else => {},
            };
            const stored_session = if (session_id) |sid| try self_.allocator.dupe(u8, sid) else null;
            errdefer if (stored_session) |sid| self_.allocator.free(sid);

            const new_entries = try self_.allocator.realloc(entries, entries.len + 1);
            entries = new_entries;
            entries[entries.len - 1] = .{
                .id = id,
                .key = stored_key,
                .content = stored_content,
                .category = stored_category,
                .timestamp = timestamp,
                .session_id = stored_session,
            };
        }

        try self_.writeEntries(entries, self_.allocator);
    }

    fn implRecall(ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const all = try self_.readAllEntries(allocator);
        defer allocator.free(all);

        const query_lower = try std.ascii.allocLowerString(allocator, query);
        defer allocator.free(query_lower);

        var keywords: std.ArrayList([]const u8) = .empty;
        defer keywords.deinit(allocator);
        var kw_iter = std.mem.tokenizeAny(u8, query_lower, " \t\n\r");
        while (kw_iter.next()) |word| try keywords.append(allocator, word);

        if (keywords.items.len == 0) {
            for (all) |*e| @constCast(e).deinit(allocator);
            return allocator.alloc(MemoryEntry, 0);
        }

        var scored: std.ArrayList(MemoryEntry) = .empty;
        errdefer {
            for (scored.items) |*e| e.deinit(allocator);
            scored.deinit(allocator);
        }

        for (all) |*entry_ptr| {
            var entry = entry_ptr.*;
            if (!sameSession(entry.session_id, session_id)) {
                @constCast(entry_ptr).deinit(allocator);
                continue;
            }
            const content_lower = try std.ascii.allocLowerString(allocator, entry.content);
            defer allocator.free(content_lower);
            const key_lower = try std.ascii.allocLowerString(allocator, entry.key);
            defer allocator.free(key_lower);

            var matched: usize = 0;
            for (keywords.items) |kw| {
                if (std.mem.indexOf(u8, content_lower, kw) != null) matched += 1;
                if (std.mem.indexOf(u8, key_lower, kw) != null) matched += 1;
            }

            if (matched > 0) {
                const score: f64 = @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(keywords.items.len));
                entry.score = score;
                try scored.append(allocator, entry);
            } else {
                @constCast(entry_ptr).deinit(allocator);
            }
        }

        std.mem.sort(MemoryEntry, scored.items, {}, struct {
            fn lessThan(_: void, a: MemoryEntry, b: MemoryEntry) bool {
                return (b.score orelse 0) < (a.score orelse 0);
            }
        }.lessThan);

        if (scored.items.len > limit) {
            for (scored.items[limit..]) |*e| e.deinit(allocator);
            scored.shrinkRetainingCapacity(limit);
        }

        return scored.toOwnedSlice(allocator);
    }

    fn implGet(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const all = try self_.readAllEntries(allocator);
        defer allocator.free(all);

        var found: ?MemoryEntry = null;
        for (all) |*entry_ptr| {
            const entry = entry_ptr.*;
            if (std.mem.eql(u8, entry.key, key)) {
                if (entry.session_id == null) {
                    if (found) |*prev| prev.deinit(allocator);
                    found = entry;
                } else if (found == null) {
                    found = entry;
                } else {
                    @constCast(entry_ptr).deinit(allocator);
                }
            } else {
                @constCast(entry_ptr).deinit(allocator);
            }
        }

        return found;
    }

    fn implGetScoped(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8) anyerror!?MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        const all = try self_.readAllEntries(allocator);
        defer allocator.free(all);

        var found: ?MemoryEntry = null;
        for (all) |*entry_ptr| {
            if (std.mem.eql(u8, entry_ptr.key, key) and sameSession(entry_ptr.session_id, session_id)) {
                if (found) |*prev| prev.deinit(allocator);
                found = entry_ptr.*;
            } else {
                @constCast(entry_ptr).deinit(allocator);
            }
        }

        return found;
    }

    fn implList(ptr: *anyopaque, allocator: std.mem.Allocator, category: ?MemoryCategory, session_id: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const all = try self_.readAllEntries(allocator);
        defer allocator.free(all);

        if (category == null) {
            var filtered_all: std.ArrayList(MemoryEntry) = .empty;
            errdefer {
                for (filtered_all.items) |*e| e.deinit(allocator);
                filtered_all.deinit(allocator);
            }

            for (all) |*entry_ptr| {
                if (sameSession(entry_ptr.session_id, session_id)) {
                    try filtered_all.append(allocator, entry_ptr.*);
                } else {
                    @constCast(entry_ptr).deinit(allocator);
                }
            }

            return filtered_all.toOwnedSlice(allocator);
        }

        var filtered: std.ArrayList(MemoryEntry) = .empty;
        errdefer {
            for (filtered.items) |*e| e.deinit(allocator);
            filtered.deinit(allocator);
        }

        for (all) |*entry_ptr| {
            var entry = entry_ptr.*;
            if (entry.category.eql(category.?) and sameSession(entry.session_id, session_id)) {
                try filtered.append(allocator, entry);
            } else {
                @constCast(entry_ptr).deinit(allocator);
            }
        }

        return filtered.toOwnedSlice(allocator);
    }

    fn implForget(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        const all = try self_.readAllEntries(self_.allocator);
        defer root.freeEntries(self_.allocator, all);

        var kept: std.ArrayListUnmanaged(MemoryEntry) = .empty;
        defer {
            for (kept.items) |*entry| entry.deinit(self_.allocator);
            kept.deinit(self_.allocator);
        }

        var deleted = false;
        for (all) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                deleted = true;
                continue;
            }
            try kept.append(self_.allocator, .{
                .id = try self_.allocator.dupe(u8, entry.id),
                .key = try self_.allocator.dupe(u8, entry.key),
                .content = try self_.allocator.dupe(u8, entry.content),
                .category = switch (entry.category) {
                    .custom => |name| .{ .custom = try self_.allocator.dupe(u8, name) },
                    else => entry.category,
                },
                .timestamp = try self_.allocator.dupe(u8, entry.timestamp),
                .session_id = if (entry.session_id) |sid| try self_.allocator.dupe(u8, sid) else null,
            });
        }

        if (deleted) try self_.writeEntries(kept.items, self_.allocator);
        return deleted;
    }

    fn implForgetScoped(ptr: *anyopaque, key: []const u8, session_id: ?[]const u8) anyerror!bool {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        const all = try self_.readAllEntries(self_.allocator);
        defer root.freeEntries(self_.allocator, all);

        var kept: std.ArrayListUnmanaged(MemoryEntry) = .empty;
        defer {
            for (kept.items) |*entry| entry.deinit(self_.allocator);
            kept.deinit(self_.allocator);
        }

        var deleted = false;
        for (all) |entry| {
            if (std.mem.eql(u8, entry.key, key) and sameSession(entry.session_id, session_id)) {
                deleted = true;
                continue;
            }
            try kept.append(self_.allocator, .{
                .id = try self_.allocator.dupe(u8, entry.id),
                .key = try self_.allocator.dupe(u8, entry.key),
                .content = try self_.allocator.dupe(u8, entry.content),
                .category = switch (entry.category) {
                    .custom => |name| .{ .custom = try self_.allocator.dupe(u8, name) },
                    else => entry.category,
                },
                .timestamp = try self_.allocator.dupe(u8, entry.timestamp),
                .session_id = if (entry.session_id) |sid| try self_.allocator.dupe(u8, sid) else null,
            });
        }

        if (deleted) try self_.writeEntries(kept.items, self_.allocator);
        return deleted;
    }

    fn implCount(ptr: *anyopaque) anyerror!usize {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        const all = try self_.readAllEntries(self_.allocator);
        defer {
            for (all) |*entry| {
                @constCast(entry).deinit(self_.allocator);
            }
            self_.allocator.free(all);
        }
        return all.len;
    }

    fn implHealthCheck(_: *anyopaque) bool {
        return true;
    }

    fn implDeinit(ptr: *anyopaque) void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        self_.deinit();
        if (self_.owns_self) {
            self_.allocator.destroy(self_);
        }
    }

    const vtable = Memory.VTable{
        .name = &implName,
        .store = &implStore,
        .recall = &implRecall,
        .get = &implGet,
        .getScoped = &implGetScoped,
        .list = &implList,
        .forget = &implForget,
        .forgetScoped = &implForgetScoped,
        .count = &implCount,
        .healthCheck = &implHealthCheck,
        .deinit = &implDeinit,
    };

    pub fn memory(self: *Self) Memory {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn exportAllEntries(self: *Self, allocator: std.mem.Allocator) ![]MemoryEntry {
        return self.readAllEntries(allocator);
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "markdown forget removes matching entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    var mem = try MarkdownMemory.init(std.testing.allocator, base);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("key1", "value1", .core, null);
    try m.store("key2", "value2", .core, "sess-a");

    try std.testing.expect(try m.forgetScoped(std.testing.allocator, "key2", "sess-a"));
    try std.testing.expect((try m.getScoped(std.testing.allocator, "key2", "sess-a")) == null);
    try std.testing.expect(try m.forget("key1"));
    try std.testing.expect((try m.getScoped(std.testing.allocator, "key1", null)) == null);
}

test "markdown parseEntries skips empty lines" {
    const text = "line one\n\n\nline two\n";
    const entries = try MarkdownMemory.parseEntries(text, "test", .core, std.testing.allocator);
    defer {
        for (entries) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("line one", entries[0].content);
    try std.testing.expectEqualStrings("line two", entries[1].content);
}

test "markdown parseEntries skips headings" {
    const text = "# Heading\nContent under heading\n## Sub\nMore content";
    const entries = try MarkdownMemory.parseEntries(text, "test", .core, std.testing.allocator);
    defer {
        for (entries) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("Content under heading", entries[0].content);
    try std.testing.expectEqualStrings("More content", entries[1].content);
}

test "markdown parseEntries strips bullet prefix" {
    const text = "- Item one\n- Item two\nPlain line";
    const entries = try MarkdownMemory.parseEntries(text, "test", .core, std.testing.allocator);
    defer {
        for (entries) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("Item one", entries[0].content);
    try std.testing.expectEqualStrings("Item two", entries[1].content);
    try std.testing.expectEqualStrings("Plain line", entries[2].content);
}

test "markdown parseEntries generates sequential ids" {
    const text = "a\nb\nc";
    const entries = try MarkdownMemory.parseEntries(text, "myfile", .core, std.testing.allocator);
    defer {
        for (entries) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("myfile:0", entries[0].id);
    try std.testing.expectEqualStrings("myfile:1", entries[1].id);
    try std.testing.expectEqualStrings("myfile:2", entries[2].id);
}

test "markdown parseEntries empty text returns empty" {
    const entries = try MarkdownMemory.parseEntries("", "test", .core, std.testing.allocator);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "markdown parseEntries only headings returns empty" {
    const text = "# Heading\n## Another\n### Third";
    const entries = try MarkdownMemory.parseEntries(text, "test", .core, std.testing.allocator);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

test "markdown parseEntries preserves category" {
    const text = "content";
    const entries = try MarkdownMemory.parseEntries(text, "test", .daily, std.testing.allocator);
    defer {
        for (entries) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expect(entries[0].category.eql(.daily));
}

test "markdown persists exact session_id namespaces" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    var mem = try MarkdownMemory.init(std.testing.allocator, base);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("sess_key", "session data", .core, "session-123");
    try m.store("sess_key", "global data", .core, null);

    const recalled = try m.recall(std.testing.allocator, "session", 10, "session-123");
    defer {
        for (recalled) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(recalled);
    }

    try std.testing.expectEqual(@as(usize, 1), recalled.len);
    try std.testing.expect(recalled[0].session_id != null);
    try std.testing.expectEqualStrings("session-123", recalled[0].session_id.?);

    const listed = try m.list(std.testing.allocator, null, "session-123");
    defer {
        for (listed) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(listed);
    }
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expect(listed[0].session_id != null);
    try std.testing.expectEqualStrings("session-123", listed[0].session_id.?);
}

test "markdown getScoped returns entry inside isolated workspace" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    var mem = try MarkdownMemory.init(std.testing.allocator, base);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("scoped_key", "session data", .core, "session-123");

    const entry = (try m.getScoped(std.testing.allocator, "scoped_key", "session-123")).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("session data", entry.content);
    try std.testing.expectEqualStrings("session-123", entry.session_id.?);
}

test "markdown reads memory.md when MEMORY.md is absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = "memory.md",
        .data = "- legacy-memory-entry",
    });
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    var mem = try MarkdownMemory.init(std.testing.allocator, base);
    defer mem.deinit();
    const m = mem.memory();

    const recalled = try m.recall(std.testing.allocator, "legacy", 10, null);
    defer {
        for (recalled) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(recalled);
    }

    try std.testing.expectEqual(@as(usize, 1), recalled.len);
    try std.testing.expect(std.mem.indexOf(u8, recalled[0].content, "legacy-memory-entry") != null);
}

test "markdown reads both MEMORY.md and memory.md when distinct" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "MEMORY.md",
        .data = "- primary-entry",
    });

    var has_distinct_case_files = true;
    const alt = tmp.dir.createFile("memory.md", .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => blk: {
            has_distinct_case_files = false;
            break :blk null;
        },
        else => return err,
    };
    if (alt) |f| {
        defer f.close();
        try f.writeAll("- alt-entry");
    }

    if (!has_distinct_case_files) return;

    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    var mem = try MarkdownMemory.init(std.testing.allocator, base);
    defer mem.deinit();
    const m = mem.memory();

    const listed = try m.list(std.testing.allocator, .core, null);
    defer {
        for (listed) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(listed);
    }

    var found_primary = false;
    var found_alt = false;
    for (listed) |entry| {
        if (std.mem.indexOf(u8, entry.content, "primary-entry") != null) found_primary = true;
        if (std.mem.indexOf(u8, entry.content, "alt-entry") != null) found_alt = true;
    }

    try std.testing.expect(found_primary);
    try std.testing.expect(found_alt);
}

test "markdown get returns latest matching entry for duplicate key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(base);

    var mem = try MarkdownMemory.init(std.testing.allocator, base);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("dup_key", "old", .core, null);
    try m.store("dup_key", "new", .core, null);

    const entry = (try m.get(std.testing.allocator, "dup_key")).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, entry.content, "new") != null);
}
