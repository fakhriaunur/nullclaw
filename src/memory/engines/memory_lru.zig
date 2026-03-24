//! In-memory LRU memory backend.
//!
//! Pure in-memory store with LRU eviction — no disk I/O, no external
//! dependencies.  Ideal for testing, CI, and ephemeral sessions.

const std = @import("std");
const root = @import("../root.zig");
const key_codec = @import("../vector/key_codec.zig");
const Memory = root.Memory;
const MemoryCategory = root.MemoryCategory;
const MemoryEntry = root.MemoryEntry;
const MemoryEvent = root.MemoryEvent;
const MemoryEventFeedInfo = root.MemoryEventFeedInfo;
const MemoryEventInput = root.MemoryEventInput;
const MemoryEventOp = root.MemoryEventOp;
const MemoryValueKind = root.MemoryValueKind;
const ResolvedMemoryState = root.ResolvedMemoryState;

pub const InMemoryLruMemory = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(StoredEntry),
    events: std.ArrayListUnmanaged(StoredEvent),
    origin_frontiers: std.StringHashMapUnmanaged(u64),
    scoped_tombstones: std.StringHashMapUnmanaged(TombstoneMeta),
    key_tombstones: std.StringHashMapUnmanaged(TombstoneMeta),
    max_entries: usize,
    access_counter: u64,
    next_event_sequence: u64,
    compacted_through_sequence: u64 = 0,
    instance_id: []const u8 = "default",
    owns_instance_id: bool = false,
    owns_self: bool = false,

    const Self = @This();

    const StoredEntry = struct {
        key: []const u8,
        content: []const u8,
        category: MemoryCategory,
        value_kind: ?MemoryValueKind,
        session_id: ?[]const u8,
        created_at: []const u8,
        updated_at: []const u8,
        event_timestamp_ms: i64,
        event_origin_instance_id: []const u8,
        event_origin_sequence: u64,
        last_access: u64,
    };

    const StoredEvent = struct {
        sequence: u64,
        origin_instance_id: []const u8,
        origin_sequence: u64,
        timestamp_ms: i64,
        operation: MemoryEventOp,
        key: []const u8,
        session_id: ?[]const u8,
        category: ?MemoryCategory,
        value_kind: ?MemoryValueKind,
        content: ?[]const u8,
    };

    const TombstoneMeta = struct {
        timestamp_ms: i64,
        origin_instance_id: []const u8,
        origin_sequence: u64,
    };

    pub fn init(allocator: std.mem.Allocator, max_entries: usize) Self {
        return .{
            .allocator = allocator,
            .entries = .{},
            .events = .{},
            .origin_frontiers = .{},
            .scoped_tombstones = .{},
            .key_tombstones = .{},
            .max_entries = max_entries,
            .access_counter = 0,
            .next_event_sequence = 0,
        };
    }

    pub fn initWithInstanceId(allocator: std.mem.Allocator, max_entries: usize, instance_id: []const u8) !Self {
        var self = init(allocator, max_entries);
        const effective_instance_id = if (instance_id.len > 0) instance_id else "default";
        self.instance_id = try allocator.dupe(u8, effective_instance_id);
        self.owns_instance_id = true;
        return self;
    }

    pub fn deinit(self: *Self) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            self.freeStoredEntry(kv.value_ptr.*);
            self.allocator.free(kv.key_ptr.*);
        }
        self.entries.deinit(self.allocator);
        for (self.events.items) |event| self.freeStoredEvent(event);
        self.events.deinit(self.allocator);
        var frontier_it = self.origin_frontiers.iterator();
        while (frontier_it.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.origin_frontiers.deinit(self.allocator);
        var scoped_tombstone_it = self.scoped_tombstones.iterator();
        while (scoped_tombstone_it.next()) |kv| {
            self.freeTombstoneMeta(kv.value_ptr.*);
            self.allocator.free(kv.key_ptr.*);
        }
        self.scoped_tombstones.deinit(self.allocator);
        var key_tombstone_it = self.key_tombstones.iterator();
        while (key_tombstone_it.next()) |kv| {
            self.freeTombstoneMeta(kv.value_ptr.*);
            self.allocator.free(kv.key_ptr.*);
        }
        self.key_tombstones.deinit(self.allocator);
        if (self.owns_instance_id) self.allocator.free(self.instance_id);
        if (self.owns_self) {
            self.allocator.destroy(self);
        }
    }

    fn freeStoredEntry(self: *Self, entry: StoredEntry) void {
        self.allocator.free(entry.key);
        self.allocator.free(entry.content);
        self.allocator.free(entry.created_at);
        self.allocator.free(entry.updated_at);
        self.allocator.free(entry.event_origin_instance_id);
        if (entry.session_id) |sid| self.allocator.free(sid);
        switch (entry.category) {
            .custom => |name| self.allocator.free(name),
            else => {},
        }
    }

    fn freeStoredEvent(self: *Self, event: StoredEvent) void {
        self.allocator.free(event.origin_instance_id);
        self.allocator.free(event.key);
        if (event.session_id) |sid| self.allocator.free(sid);
        if (event.content) |content| self.allocator.free(content);
        if (event.category) |category| switch (category) {
            .custom => |name| self.allocator.free(name),
            else => {},
        };
    }

    fn freeTombstoneMeta(self: *Self, meta: TombstoneMeta) void {
        self.allocator.free(meta.origin_instance_id);
    }

    fn nextAccess(self: *Self) u64 {
        self.access_counter += 1;
        return self.access_counter;
    }

    fn evictLru(self: *Self) void {
        var min_access: u64 = std.math.maxInt(u64);
        var evict_key: ?[]const u8 = null;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.last_access < min_access) {
                min_access = kv.value_ptr.last_access;
                evict_key = kv.key_ptr.*;
            }
        }
        if (evict_key) |key| {
            if (self.entries.fetchRemove(key)) |removed| {
                self.freeStoredEntry(removed.value);
                self.allocator.free(removed.key);
            }
        }
    }

    fn nowTimestamp(self: *Self) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{d}", .{std.time.timestamp()});
    }

    fn timestampFromMillis(self: *Self, timestamp_ms: i64) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{d}", .{timestamp_ms});
    }

    fn dupCategory(self: *Self, cat: MemoryCategory) !MemoryCategory {
        return switch (cat) {
            .custom => |name| .{ .custom = try self.allocator.dupe(u8, name) },
            else => cat,
        };
    }

    fn dupOptionalCategory(self: *Self, cat: ?MemoryCategory) !?MemoryCategory {
        if (cat) |value| return try self.dupCategory(value);
        return null;
    }

    fn localInstanceId(self: *Self) []const u8 {
        return if (self.instance_id.len > 0) self.instance_id else "default";
    }

    fn compareEventOrder(entry: StoredEntry, input: MemoryEventInput) i8 {
        if (input.timestamp_ms < entry.event_timestamp_ms) return -1;
        if (input.timestamp_ms > entry.event_timestamp_ms) return 1;

        const order = std.mem.order(u8, input.origin_instance_id, entry.event_origin_instance_id);
        if (order == .lt) return -1;
        if (order == .gt) return 1;

        if (input.origin_sequence < entry.event_origin_sequence) return -1;
        if (input.origin_sequence > entry.event_origin_sequence) return 1;
        return 0;
    }

    fn compareEventOrderMeta(meta: TombstoneMeta, input: MemoryEventInput) i8 {
        if (input.timestamp_ms < meta.timestamp_ms) return -1;
        if (input.timestamp_ms > meta.timestamp_ms) return 1;

        const order = std.mem.order(u8, input.origin_instance_id, meta.origin_instance_id);
        if (order == .lt) return -1;
        if (order == .gt) return 1;

        if (input.origin_sequence < meta.origin_sequence) return -1;
        if (input.origin_sequence > meta.origin_sequence) return 1;
        return 0;
    }

    fn cloneEntry(allocator: std.mem.Allocator, e: StoredEntry) !MemoryEntry {
        const id = try allocator.dupe(u8, e.key);
        errdefer allocator.free(id);
        const dup_key = try allocator.dupe(u8, e.key);
        errdefer allocator.free(dup_key);
        const dup_content = try allocator.dupe(u8, e.content);
        errdefer allocator.free(dup_content);
        const dup_cat: MemoryCategory = switch (e.category) {
            .custom => |name| .{ .custom = try allocator.dupe(u8, name) },
            else => e.category,
        };
        errdefer switch (dup_cat) {
            .custom => |name| allocator.free(name),
            else => {},
        };
        const dup_ts = try allocator.dupe(u8, e.updated_at);
        errdefer allocator.free(dup_ts);
        const dup_sid = if (e.session_id) |sid| try allocator.dupe(u8, sid) else null;
        errdefer if (dup_sid) |sid| allocator.free(sid);

        return .{
            .id = id,
            .key = dup_key,
            .content = dup_content,
            .category = dup_cat,
            .timestamp = dup_ts,
            .session_id = dup_sid,
            .score = null,
        };
    }

    fn cloneEvent(self: *Self, allocator: std.mem.Allocator, e: StoredEvent) !MemoryEvent {
        const dup_category = if (e.category) |category|
            switch (category) {
                .custom => |name| MemoryCategory{ .custom = try allocator.dupe(u8, name) },
                else => category,
            }
        else
            null;
        errdefer if (dup_category) |category| switch (category) {
            .custom => |name| allocator.free(name),
            else => {},
        };

        const dup_sid = if (e.session_id) |sid| try allocator.dupe(u8, sid) else null;
        errdefer if (dup_sid) |sid| allocator.free(sid);
        const dup_content = if (e.content) |content| try allocator.dupe(u8, content) else null;
        errdefer if (dup_content) |content| allocator.free(content);

        _ = self;
        return .{
            .schema_version = 1,
            .sequence = e.sequence,
            .origin_instance_id = try allocator.dupe(u8, e.origin_instance_id),
            .origin_sequence = e.origin_sequence,
            .timestamp_ms = e.timestamp_ms,
            .operation = e.operation,
            .key = try allocator.dupe(u8, e.key),
            .session_id = dup_sid,
            .category = dup_category,
            .value_kind = e.value_kind,
            .content = dup_content,
        };
    }

    fn appendEventRecord(self: *Self, input: MemoryEventInput) !void {
        self.next_event_sequence += 1;
        try self.events.append(self.allocator, .{
            .sequence = self.next_event_sequence,
            .origin_instance_id = try self.allocator.dupe(u8, input.origin_instance_id),
            .origin_sequence = input.origin_sequence,
            .timestamp_ms = input.timestamp_ms,
            .operation = input.operation,
            .key = try self.allocator.dupe(u8, input.key),
            .session_id = if (input.session_id) |sid| try self.allocator.dupe(u8, sid) else null,
            .category = try self.dupOptionalCategory(input.category),
            .value_kind = input.value_kind,
            .content = if (input.content) |content| try self.allocator.dupe(u8, content) else null,
        });
    }

    fn updateFrontier(self: *Self, origin_instance_id: []const u8, origin_sequence: u64) !void {
        if (self.origin_frontiers.getPtr(origin_instance_id)) |frontier| {
            if (origin_sequence > frontier.*) frontier.* = origin_sequence;
            return;
        }
        try self.origin_frontiers.put(self.allocator, try self.allocator.dupe(u8, origin_instance_id), origin_sequence);
    }

    fn nextLocalOriginSequence(self: *Self) u64 {
        return if (self.origin_frontiers.get(self.localInstanceId())) |frontier| frontier + 1 else 1;
    }

    fn upsertKeyTombstone(self: *Self, key: []const u8, input: MemoryEventInput) !void {
        if (self.key_tombstones.getPtr(key)) |existing| {
            if (compareEventOrderMeta(existing.*, input) <= 0) return;
            self.allocator.free(existing.origin_instance_id);
            existing.* = .{
                .timestamp_ms = input.timestamp_ms,
                .origin_instance_id = try self.allocator.dupe(u8, input.origin_instance_id),
                .origin_sequence = input.origin_sequence,
            };
            return;
        }

        try self.key_tombstones.put(self.allocator, try self.allocator.dupe(u8, key), .{
            .timestamp_ms = input.timestamp_ms,
            .origin_instance_id = try self.allocator.dupe(u8, input.origin_instance_id),
            .origin_sequence = input.origin_sequence,
        });
    }

    fn upsertScopedTombstone(self: *Self, key: []const u8, session_id: ?[]const u8, input: MemoryEventInput) !void {
        const storage_key = try key_codec.encode(self.allocator, key, session_id);
        defer self.allocator.free(storage_key);

        if (self.scoped_tombstones.getPtr(storage_key)) |existing| {
            if (compareEventOrderMeta(existing.*, input) <= 0) return;
            self.allocator.free(existing.origin_instance_id);
            existing.* = .{
                .timestamp_ms = input.timestamp_ms,
                .origin_instance_id = try self.allocator.dupe(u8, input.origin_instance_id),
                .origin_sequence = input.origin_sequence,
            };
            return;
        }

        try self.scoped_tombstones.put(self.allocator, try self.allocator.dupe(u8, storage_key), .{
            .timestamp_ms = input.timestamp_ms,
            .origin_instance_id = try self.allocator.dupe(u8, input.origin_instance_id),
            .origin_sequence = input.origin_sequence,
        });
    }

    fn applyPutResolved(self: *Self, input: MemoryEventInput, resolved_state: ResolvedMemoryState) !void {
        const storage_key = try key_codec.encode(self.allocator, input.key, input.session_id);
        defer self.allocator.free(storage_key);

        if (self.key_tombstones.get(input.key)) |meta| {
            if (compareEventOrderMeta(meta, input) <= 0) return;
        }
        if (self.scoped_tombstones.get(storage_key)) |meta| {
            if (compareEventOrderMeta(meta, input) <= 0) return;
        }

        if (self.entries.getPtr(storage_key)) |existing| {
            if (compareEventOrder(existing.*, input) < 0) return;

            self.allocator.free(existing.content);
            existing.content = try self.allocator.dupe(u8, resolved_state.content);
            self.allocator.free(existing.updated_at);
            existing.updated_at = try self.timestampFromMillis(input.timestamp_ms);
            switch (existing.category) {
                .custom => |name| self.allocator.free(name),
                else => {},
            }
            existing.category = try self.dupCategory(resolved_state.category);
            existing.value_kind = resolved_state.value_kind;
            if (existing.session_id) |sid| self.allocator.free(sid);
            existing.session_id = if (input.session_id) |sid| try self.allocator.dupe(u8, sid) else null;
            existing.event_timestamp_ms = input.timestamp_ms;
            self.allocator.free(existing.event_origin_instance_id);
            existing.event_origin_instance_id = try self.allocator.dupe(u8, input.origin_instance_id);
            existing.event_origin_sequence = input.origin_sequence;
            existing.last_access = self.nextAccess();
            return;
        }

        if (self.max_entries == 0) return;
        if (self.entries.count() >= self.max_entries) self.evictLru();

        const ts = try self.timestampFromMillis(input.timestamp_ms);
        errdefer self.allocator.free(ts);
        const ts2 = try self.allocator.dupe(u8, ts);
        errdefer self.allocator.free(ts2);

        const stored = StoredEntry{
            .key = try self.allocator.dupe(u8, input.key),
            .content = try self.allocator.dupe(u8, resolved_state.content),
            .category = try self.dupCategory(resolved_state.category),
            .value_kind = resolved_state.value_kind,
            .session_id = if (input.session_id) |sid| try self.allocator.dupe(u8, sid) else null,
            .created_at = ts,
            .updated_at = ts2,
            .event_timestamp_ms = input.timestamp_ms,
            .event_origin_instance_id = try self.allocator.dupe(u8, input.origin_instance_id),
            .event_origin_sequence = input.origin_sequence,
            .last_access = self.nextAccess(),
        };

        try self.entries.put(self.allocator, try self.allocator.dupe(u8, storage_key), stored);
    }

    fn applyDeleteScoped(self: *Self, input: MemoryEventInput) !void {
        const storage_key = try key_codec.encode(self.allocator, input.key, input.session_id);
        defer self.allocator.free(storage_key);

        if (self.entries.getPtr(storage_key)) |existing| {
            if (compareEventOrder(existing.*, input) < 0) return;
            if (self.entries.fetchRemove(storage_key)) |removed| {
                self.freeStoredEntry(removed.value);
                self.allocator.free(removed.key);
            }
        }

        try self.upsertScopedTombstone(input.key, input.session_id, input);
    }

    fn applyDeleteAll(self: *Self, input: MemoryEventInput) !void {
        var to_remove: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (to_remove.items) |key| self.allocator.free(key);
            to_remove.deinit(self.allocator);
        }

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (!std.mem.eql(u8, kv.value_ptr.key, input.key)) continue;
            if (compareEventOrder(kv.value_ptr.*, input) < 0) continue;
            try to_remove.append(self.allocator, try self.allocator.dupe(u8, kv.key_ptr.*));
        }

        for (to_remove.items) |storage_key| {
            if (self.entries.fetchRemove(storage_key)) |removed| {
                self.freeStoredEntry(removed.value);
                self.allocator.free(removed.key);
            }
        }

        try self.upsertKeyTombstone(input.key, input);
    }

    fn applyEventInternal(self: *Self, input: MemoryEventInput, record_event: bool) !void {
        if (self.origin_frontiers.get(input.origin_instance_id)) |frontier| {
            if (input.origin_sequence <= frontier) return;
        }

        if (record_event) try self.appendEventRecord(input);

        switch (input.operation) {
            .put, .merge_object, .merge_string_set => {
                const storage_key = try key_codec.encode(self.allocator, input.key, input.session_id);
                defer self.allocator.free(storage_key);
                const existing = self.entries.getPtr(storage_key);
                const resolved_state = try root.resolveMemoryEventState(
                    self.allocator,
                    if (existing) |entry| entry.content else null,
                    if (existing) |entry| entry.category else null,
                    if (existing) |entry| entry.value_kind else null,
                    input,
                ) orelse return error.InvalidEvent;
                defer resolved_state.deinit(self.allocator);
                try self.applyPutResolved(input, resolved_state);
            },
            .delete_scoped => try self.applyDeleteScoped(input),
            .delete_all => try self.applyDeleteAll(input),
        }

        try self.updateFrontier(input.origin_instance_id, input.origin_sequence);
    }

    fn findDefaultEntryPtr(self: *Self, key: []const u8) ?*StoredEntry {
        var best: ?*StoredEntry = null;
        var best_is_global = false;
        var best_access: u64 = 0;

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (!std.mem.eql(u8, kv.value_ptr.key, key)) continue;
            const is_global = kv.value_ptr.session_id == null;
            if (best == null or
                (is_global and !best_is_global) or
                (is_global == best_is_global and kv.value_ptr.last_access > best_access))
            {
                best = kv.value_ptr;
                best_is_global = is_global;
                best_access = kv.value_ptr.last_access;
            }
        }

        return best;
    }

    // ── vtable impl fns ────────────────────────────────────────────

    fn implName(_: *anyopaque) []const u8 {
        return "memory_lru";
    }

    fn implStore(ptr: *anyopaque, key: []const u8, content: []const u8, category: MemoryCategory, session_id: ?[]const u8) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        const next_origin_sequence = self_.nextLocalOriginSequence();
        const input = MemoryEventInput{
            .origin_instance_id = self_.localInstanceId(),
            .origin_sequence = next_origin_sequence,
            .timestamp_ms = std.time.milliTimestamp(),
            .operation = .put,
            .key = key,
            .session_id = session_id,
            .category = category,
            .content = content,
        };
        try self_.applyEventInternal(input, true);
    }

    fn implRecall(ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        // Collect matches via substring search on key and content.
        const Pair = struct { entry: StoredEntry, map_key: []const u8 };
        var matches: std.ArrayList(Pair) = .empty;
        defer matches.deinit(allocator);

        var it = self_.entries.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            // Session filter
            if (session_id) |filter_sid| {
                if (e.session_id) |esid| {
                    if (!std.mem.eql(u8, esid, filter_sid)) continue;
                } else continue;
            }
            // Substring match on key or content
            if (std.mem.indexOf(u8, e.key, query) != null or
                std.mem.indexOf(u8, e.content, query) != null)
            {
                try matches.append(allocator, .{ .entry = e, .map_key = kv.key_ptr.* });
            }
        }

        // Sort by last_access descending (most recent first).
        std.mem.sort(Pair, matches.items, {}, struct {
            fn lessThan(_: void, a: Pair, b: Pair) bool {
                return a.entry.last_access > b.entry.last_access;
            }
        }.lessThan);

        const result_len = @min(matches.items.len, limit);
        const results = try allocator.alloc(MemoryEntry, result_len);
        var filled: usize = 0;
        errdefer {
            for (results[0..filled]) |*e| e.deinit(allocator);
            allocator.free(results);
        }

        for (results, 0..) |*slot, i| {
            const src = matches.items[i].entry;
            slot.* = try cloneEntry(allocator, src);
            filled += 1;
        }

        return results;
    }

    fn implGet(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const entry_ptr = self_.findDefaultEntryPtr(key) orelse return null;

        // Update access timestamp.
        entry_ptr.last_access = self_.nextAccess();

        return try cloneEntry(allocator, entry_ptr.*);
    }

    fn implGetScoped(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8) anyerror!?MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        const storage_key = try key_codec.encode(allocator, key, session_id);
        defer allocator.free(storage_key);

        const entry_ptr = self_.entries.getPtr(storage_key) orelse return null;
        entry_ptr.last_access = self_.nextAccess();
        return try cloneEntry(allocator, entry_ptr.*);
    }

    fn implList(ptr: *anyopaque, allocator: std.mem.Allocator, category: ?MemoryCategory, session_id: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        var results: std.ArrayList(MemoryEntry) = .empty;
        errdefer {
            for (results.items) |*e| e.deinit(allocator);
            results.deinit(allocator);
        }

        var it = self_.entries.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;

            // Category filter
            if (category) |cat| {
                if (!e.category.eql(cat)) continue;
            }

            // Session filter
            if (session_id) |filter_sid| {
                if (e.session_id) |esid| {
                    if (!std.mem.eql(u8, esid, filter_sid)) continue;
                } else continue;
            }

            try results.append(allocator, try cloneEntry(allocator, e));
        }

        return results.toOwnedSlice(allocator);
    }

    fn implForget(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        var it = self_.entries.iterator();
        var removed_any = false;
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.key, key)) {
                removed_any = true;
                break;
            }
        }
        if (!removed_any) return false;

        const next_origin_sequence = self_.nextLocalOriginSequence();
        const input = MemoryEventInput{
            .origin_instance_id = self_.localInstanceId(),
            .origin_sequence = next_origin_sequence,
            .timestamp_ms = std.time.milliTimestamp(),
            .operation = .delete_all,
            .key = key,
        };
        try self_.applyEventInternal(input, true);
        return true;
    }

    fn implForgetScoped(ptr: *anyopaque, key: []const u8, session_id: ?[]const u8) anyerror!bool {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        const current = try implGetScoped(ptr, self_.allocator, key, session_id);
        if (current == null) return false;
        current.?.deinit(self_.allocator);

        const next_origin_sequence = self_.nextLocalOriginSequence();
        const input = MemoryEventInput{
            .origin_instance_id = self_.localInstanceId(),
            .origin_sequence = next_origin_sequence,
            .timestamp_ms = std.time.milliTimestamp(),
            .operation = .delete_scoped,
            .key = key,
            .session_id = session_id,
        };
        try self_.applyEventInternal(input, true);
        return true;
    }

    fn implListEvents(ptr: *anyopaque, allocator: std.mem.Allocator, after_sequence: u64, limit: usize) anyerror![]MemoryEvent {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        if (after_sequence < self_.compacted_through_sequence) return error.CursorExpired;
        var events: std.ArrayListUnmanaged(MemoryEvent) = .empty;
        errdefer {
            for (events.items) |*event| event.deinit(allocator);
            events.deinit(allocator);
        }

        for (self_.events.items) |event| {
            if (event.sequence <= after_sequence) continue;
            try events.append(allocator, try self_.cloneEvent(allocator, event));
            if (events.items.len >= limit) break;
        }

        return events.toOwnedSlice(allocator);
    }

    fn implApplyEvent(ptr: *anyopaque, input: MemoryEventInput) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.applyEventInternal(input, true);
    }

    fn implLastEventSequence(ptr: *anyopaque) anyerror!u64 {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        return self_.next_event_sequence;
    }

    fn implEventFeedInfo(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!MemoryEventFeedInfo {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        return .{
            .instance_id = try allocator.dupe(u8, self_.localInstanceId()),
            .last_sequence = self_.next_event_sequence,
            .next_local_origin_sequence = self_.nextLocalOriginSequence(),
            .supports_compaction = true,
            .compacted_through_sequence = self_.compacted_through_sequence,
            .oldest_available_sequence = self_.compacted_through_sequence + 1,
        };
    }

    fn implCompactEvents(ptr: *anyopaque) anyerror!u64 {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        self_.compacted_through_sequence = self_.next_event_sequence;
        for (self_.events.items) |event| self_.freeStoredEvent(event);
        self_.events.clearRetainingCapacity();
        return self_.compacted_through_sequence;
    }

    fn implCount(ptr: *anyopaque) anyerror!usize {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        return self_.entries.count();
    }

    fn implHealthCheck(_: *anyopaque) bool {
        return true;
    }

    fn implDeinit(ptr: *anyopaque) void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        self_.deinit();
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
        .listEvents = &implListEvents,
        .applyEvent = &implApplyEvent,
        .lastEventSequence = &implLastEventSequence,
        .eventFeedInfo = &implEventFeedInfo,
        .compactEvents = &implCompactEvents,
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
};

// ── Tests ──────────────────────────────────────────────────────────

test "empty state: get returns null, recall returns empty, count=0" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 10);
    defer mem.deinit();
    const m = mem.memory();

    try std.testing.expectEqualStrings("memory_lru", m.name());
    try std.testing.expect(m.healthCheck());
    try std.testing.expectEqual(@as(usize, 0), try m.count());

    const got = try m.get(std.testing.allocator, "nonexistent");
    try std.testing.expect(got == null);

    const recalled = try m.recall(std.testing.allocator, "anything", 10, null);
    defer std.testing.allocator.free(recalled);
    try std.testing.expectEqual(@as(usize, 0), recalled.len);

    const listed = try m.list(std.testing.allocator, null, null);
    defer std.testing.allocator.free(listed);
    try std.testing.expectEqual(@as(usize, 0), listed.len);
}

test "basic store/get/recall/forget cycle" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    // Store
    try m.store("greeting", "hello world", .core, null);
    try std.testing.expectEqual(@as(usize, 1), try m.count());

    // Get
    {
        const entry = (try m.get(std.testing.allocator, "greeting")).?;
        defer entry.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("greeting", entry.key);
        try std.testing.expectEqualStrings("hello world", entry.content);
        try std.testing.expect(entry.category.eql(.core));
    }

    // Recall via substring
    {
        const results = try m.recall(std.testing.allocator, "hello", 10, null);
        defer root.freeEntries(std.testing.allocator, results);
        try std.testing.expectEqual(@as(usize, 1), results.len);
        try std.testing.expectEqualStrings("hello world", results[0].content);
    }

    // Forget
    const forgotten = try m.forget("greeting");
    try std.testing.expect(forgotten);
    try std.testing.expectEqual(@as(usize, 0), try m.count());

    // Forget nonexistent returns false
    const forgotten2 = try m.forget("greeting");
    try std.testing.expect(!forgotten2);
}

test "update existing key within same namespace" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("key1", "original", .core, "sess-1");
    try m.store("key1", "updated", .daily, "sess-1");
    try std.testing.expectEqual(@as(usize, 1), try m.count());

    const entry = (try m.getScoped(std.testing.allocator, "key1", "sess-1")).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("updated", entry.content);
    try std.testing.expect(entry.category.eql(.daily));
    try std.testing.expectEqualStrings("sess-1", entry.session_id.?);
}

test "LRU eviction: oldest entry evicted at capacity" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 3);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "first", .core, null);
    try m.store("b", "second", .core, null);
    try m.store("c", "third", .core, null);
    try std.testing.expectEqual(@as(usize, 3), try m.count());

    // Adding a 4th should evict "a" (oldest)
    try m.store("d", "fourth", .core, null);
    try std.testing.expectEqual(@as(usize, 3), try m.count());

    const got_a = try m.get(std.testing.allocator, "a");
    try std.testing.expect(got_a == null);

    const got_d = (try m.get(std.testing.allocator, "d")).?;
    defer got_d.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("fourth", got_d.content);
}

test "eviction order: accessing middle entry protects it" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 3);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "first", .core, null);
    try m.store("b", "second", .core, null);
    try m.store("c", "third", .core, null);

    // Access "a" — moves it to front, so "b" becomes the LRU candidate.
    {
        const entry = (try m.get(std.testing.allocator, "a")).?;
        defer entry.deinit(std.testing.allocator);
    }

    // Insert "d", should evict "b" (least recently accessed)
    try m.store("d", "fourth", .core, null);
    try std.testing.expectEqual(@as(usize, 3), try m.count());

    const got_b = try m.get(std.testing.allocator, "b");
    try std.testing.expect(got_b == null);

    // "a" is still alive
    const got_a = (try m.get(std.testing.allocator, "a")).?;
    defer got_a.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("first", got_a.content);
}

test "recall with substring matching" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("user_pref", "dark mode enabled", .core, null);
    try m.store("api_key", "sk-12345", .core, null);
    try m.store("note", "remember to buy milk", .daily, null);

    // Search for "mode" — matches "dark mode enabled"
    {
        const results = try m.recall(std.testing.allocator, "mode", 10, null);
        defer root.freeEntries(std.testing.allocator, results);
        try std.testing.expectEqual(@as(usize, 1), results.len);
        try std.testing.expectEqualStrings("user_pref", results[0].key);
    }

    // Search for "key" — matches key "api_key"
    {
        const results = try m.recall(std.testing.allocator, "key", 10, null);
        defer root.freeEntries(std.testing.allocator, results);
        try std.testing.expectEqual(@as(usize, 1), results.len);
        try std.testing.expectEqualStrings("api_key", results[0].key);
    }

    // Search for "e" — matches all three
    {
        const results = try m.recall(std.testing.allocator, "e", 10, null);
        defer root.freeEntries(std.testing.allocator, results);
        try std.testing.expectEqual(@as(usize, 3), results.len);
    }
}

test "recall with session_id filter" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k1", "data for session A", .core, "sess-A");
    try m.store("k2", "data for session B", .core, "sess-B");
    try m.store("k3", "data no session", .core, null);

    // Filter to sess-A
    {
        const results = try m.recall(std.testing.allocator, "data", 10, "sess-A");
        defer root.freeEntries(std.testing.allocator, results);
        try std.testing.expectEqual(@as(usize, 1), results.len);
        try std.testing.expectEqualStrings("k1", results[0].key);
    }

    // No filter — all match
    {
        const results = try m.recall(std.testing.allocator, "data", 10, null);
        defer root.freeEntries(std.testing.allocator, results);
        try std.testing.expectEqual(@as(usize, 3), results.len);
    }
}

test "list by category filter" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("core1", "c1", .core, null);
    try m.store("core2", "c2", .core, null);
    try m.store("daily1", "d1", .daily, null);
    try m.store("conv1", "v1", .conversation, null);

    // List core only
    {
        const results = try m.list(std.testing.allocator, .core, null);
        defer root.freeEntries(std.testing.allocator, results);
        try std.testing.expectEqual(@as(usize, 2), results.len);
    }

    // List daily only
    {
        const results = try m.list(std.testing.allocator, .daily, null);
        defer root.freeEntries(std.testing.allocator, results);
        try std.testing.expectEqual(@as(usize, 1), results.len);
    }

    // List all (no filter)
    {
        const results = try m.list(std.testing.allocator, null, null);
        defer root.freeEntries(std.testing.allocator, results);
        try std.testing.expectEqual(@as(usize, 4), results.len);
    }
}

test "count accuracy after store/forget" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try std.testing.expectEqual(@as(usize, 0), try m.count());
    try m.store("a", "1", .core, null);
    try std.testing.expectEqual(@as(usize, 1), try m.count());
    try m.store("b", "2", .core, null);
    try std.testing.expectEqual(@as(usize, 2), try m.count());
    _ = try m.forget("a");
    try std.testing.expectEqual(@as(usize, 1), try m.count());
    _ = try m.forget("b");
    try std.testing.expectEqual(@as(usize, 0), try m.count());
}

test "session_id accepted on store" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k", "v", .core, "session-42");

    const recalled = try m.recall(std.testing.allocator, "v", 10, "session-42");
    defer root.freeEntries(std.testing.allocator, recalled);
    try std.testing.expectEqual(@as(usize, 1), recalled.len);

    const listed = try m.list(std.testing.allocator, null, "session-42");
    defer root.freeEntries(std.testing.allocator, listed);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
}

test "same logical key can exist in global and scoped namespaces" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("shared", "global", .core, null);
    try m.store("shared", "scoped", .core, "sess-a");

    const global_entry = (try m.getScoped(std.testing.allocator, "shared", null)).?;
    defer global_entry.deinit(std.testing.allocator);
    try std.testing.expect(global_entry.session_id == null);
    try std.testing.expectEqualStrings("global", global_entry.content);

    const scoped_entry = (try m.getScoped(std.testing.allocator, "shared", "sess-a")).?;
    defer scoped_entry.deinit(std.testing.allocator);
    try std.testing.expect(scoped_entry.session_id != null);
    try std.testing.expectEqualStrings("sess-a", scoped_entry.session_id.?);
    try std.testing.expectEqualStrings("scoped", scoped_entry.content);
}

test "forgetScoped removes only matching namespace in LRU" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("shared", "global", .core, null);
    try m.store("shared", "scoped", .core, "sess-a");

    try std.testing.expect(try m.forgetScoped(std.testing.allocator, "shared", "sess-a"));
    try std.testing.expect(try m.getScoped(std.testing.allocator, "shared", "sess-a") == null);

    const global_entry = (try m.getScoped(std.testing.allocator, "shared", null)).?;
    defer global_entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("global", global_entry.content);
}

test "recall respects limit" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "data", .core, null);
    try m.store("b", "data", .core, null);
    try m.store("c", "data", .core, null);

    const results = try m.recall(std.testing.allocator, "data", 2, null);
    defer root.freeEntries(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "custom category preserved" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k", "v", .{ .custom = "my_cat" }, null);
    const entry = (try m.get(std.testing.allocator, "k")).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("my_cat", entry.category.custom);
}

// ── R3 deep review tests ──────────────────────────────────────────

test "LRU store and get with empty key" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("", "content for empty key", .core, null);
    try std.testing.expectEqual(@as(usize, 1), try m.count());

    const entry = (try m.get(std.testing.allocator, "")).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", entry.key);
    try std.testing.expectEqualStrings("content for empty key", entry.content);
}

test "LRU store and get with empty content" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k", "", .core, null);
    const entry = (try m.get(std.testing.allocator, "k")).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", entry.content);
}

test "LRU store with special chars in key and content" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    const key = "key with \"quotes\" and 'apostrophes' and %wildcards%";
    const content = "line1\nline2\ttab\r\nwindows";
    try m.store(key, content, .core, null);

    const entry = (try m.get(std.testing.allocator, key)).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(key, entry.key);
    try std.testing.expectEqualStrings(content, entry.content);
}

test "LRU recall with empty query matches everything" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "alpha", .core, null);
    try m.store("b", "beta", .core, null);

    // Empty string is substring of everything
    const results = try m.recall(std.testing.allocator, "", 10, null);
    defer root.freeEntries(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "LRU same key supports null and value session_id" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k", "v", .core, null);
    {
        const entry = (try m.get(std.testing.allocator, "k")).?;
        defer entry.deinit(std.testing.allocator);
        try std.testing.expect(entry.session_id == null);
    }

    try m.store("k", "v2", .core, "sess-new");
    {
        try std.testing.expectEqual(@as(usize, 2), try m.count());

        const global_entry = (try m.getScoped(std.testing.allocator, "k", null)).?;
        defer global_entry.deinit(std.testing.allocator);
        try std.testing.expect(global_entry.session_id == null);

        const scoped_entry = (try m.getScoped(std.testing.allocator, "k", "sess-new")).?;
        defer scoped_entry.deinit(std.testing.allocator);
        try std.testing.expect(scoped_entry.session_id != null);
        try std.testing.expectEqualStrings("sess-new", scoped_entry.session_id.?);
    }
}

test "LRU same key supports value and null session_id" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k", "v", .core, "sess-old");
    try m.store("k", "v2", .core, null);

    try std.testing.expectEqual(@as(usize, 2), try m.count());

    const scoped_entry = (try m.getScoped(std.testing.allocator, "k", "sess-old")).?;
    defer scoped_entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("sess-old", scoped_entry.session_id.?);

    const global_entry = (try m.getScoped(std.testing.allocator, "k", null)).?;
    defer global_entry.deinit(std.testing.allocator);
    try std.testing.expect(global_entry.session_id == null);
}

test "LRU list with session_id filter" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k1", "v1", .core, "sess-a");
    try m.store("k2", "v2", .core, "sess-b");
    try m.store("k3", "v3", .core, null);

    const list_a = try m.list(std.testing.allocator, null, "sess-a");
    defer root.freeEntries(std.testing.allocator, list_a);
    try std.testing.expectEqual(@as(usize, 1), list_a.len);
    try std.testing.expectEqualStrings("k1", list_a[0].key);
}

test "LRU list with category and session_id combined" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k1", "v1", .core, "sess-a");
    try m.store("k2", "v2", .daily, "sess-a");
    try m.store("k3", "v3", .core, "sess-b");

    const results = try m.list(std.testing.allocator, .core, "sess-a");
    defer root.freeEntries(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("k1", results[0].key);
}

test "LRU recall returns most recently accessed first" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "common", .core, null);
    try m.store("b", "common", .core, null);
    try m.store("c", "common", .core, null);

    // Access "a" last, so it should come first in recall results
    {
        const entry = (try m.get(std.testing.allocator, "a")).?;
        defer entry.deinit(std.testing.allocator);
    }

    const results = try m.recall(std.testing.allocator, "common", 10, null);
    defer root.freeEntries(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 3), results.len);
    // First result should be "a" (most recently accessed)
    try std.testing.expectEqualStrings("a", results[0].key);
}

test "LRU recall with session_id returns only matching" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k1", "shared data", .core, "sess-a");
    try m.store("k2", "shared data", .core, "sess-b");
    try m.store("k3", "shared data", .core, null);

    const results = try m.recall(std.testing.allocator, "shared", 10, "sess-a");
    defer root.freeEntries(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("k1", results[0].key);
}

test "LRU forget nonexistent key returns false" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 100);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "exists", .core, null);
    const result = try m.forget("nonexistent");
    try std.testing.expect(!result);
    try std.testing.expectEqual(@as(usize, 1), try m.count());
}

test "LRU get on nonexistent key does not increment access counter" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 3);
    defer mem.deinit();
    const m = mem.memory();

    // Access counter starts at 0
    try std.testing.expectEqual(@as(u64, 0), mem.access_counter);

    const result = try m.get(std.testing.allocator, "nonexistent");
    try std.testing.expect(result == null);

    // Access counter should still be 0 (no entry touched)
    try std.testing.expectEqual(@as(u64, 0), mem.access_counter);
}

test "LRU eviction with capacity 1" {
    var mem = InMemoryLruMemory.init(std.testing.allocator, 1);
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "first", .core, null);
    try std.testing.expectEqual(@as(usize, 1), try m.count());

    try m.store("b", "second", .core, null);
    try std.testing.expectEqual(@as(usize, 1), try m.count());

    // "a" should be evicted
    const got_a = try m.get(std.testing.allocator, "a");
    try std.testing.expect(got_a == null);

    const got_b = (try m.get(std.testing.allocator, "b")).?;
    defer got_b.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("second", got_b.content);
}

test "memory_lru event feed converges across replicas and is idempotent" {
    var source = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
    defer source.deinit();
    var replica = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-b");
    defer replica.deinit();

    const source_mem = source.memory();
    const replica_mem = replica.memory();

    try source_mem.store("preferences.theme", "dark", .core, null);
    try source_mem.store("preferences.tone", "formal", .core, "sess-1");
    try std.testing.expect(try source_mem.forgetScoped(std.testing.allocator, "preferences.tone", "sess-1"));

    const events = try source_mem.listEvents(std.testing.allocator, 0, 32);
    defer root.freeEvents(std.testing.allocator, events);
    try std.testing.expectEqual(@as(usize, 3), events.len);

    for (events) |event| {
        try replica_mem.applyEvent(.{
            .origin_instance_id = event.origin_instance_id,
            .origin_sequence = event.origin_sequence,
            .timestamp_ms = event.timestamp_ms,
            .operation = event.operation,
            .key = event.key,
            .session_id = event.session_id,
            .category = event.category,
            .content = event.content,
        });
    }

    const theme = (try replica_mem.getScoped(std.testing.allocator, "preferences.theme", null)).?;
    defer theme.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dark", theme.content);

    const tone = try replica_mem.getScoped(std.testing.allocator, "preferences.tone", "sess-1");
    defer if (tone) |entry| entry.deinit(std.testing.allocator);
    try std.testing.expect(tone == null);

    for (events) |event| {
        try replica_mem.applyEvent(.{
            .origin_instance_id = event.origin_instance_id,
            .origin_sequence = event.origin_sequence,
            .timestamp_ms = event.timestamp_ms,
            .operation = event.operation,
            .key = event.key,
            .session_id = event.session_id,
            .category = event.category,
            .content = event.content,
        });
    }
    try std.testing.expectEqual(@as(usize, 1), try replica_mem.count());
    try std.testing.expectEqual(@as(u64, 3), try replica_mem.lastEventSequence());
}

test "memory_lru tombstones block older cross-origin put replay" {
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "replica");
    defer mem.deinit();
    const memory = mem.memory();

    try memory.applyEvent(.{
        .origin_instance_id = "agent-delete",
        .origin_sequence = 1,
        .timestamp_ms = 2000,
        .operation = .delete_all,
        .key = "preferences.locale",
    });
    try memory.applyEvent(.{
        .origin_instance_id = "agent-put",
        .origin_sequence = 1,
        .timestamp_ms = 1000,
        .operation = .put,
        .key = "preferences.locale",
        .category = .core,
        .content = "ru",
    });

    const entry = try memory.getScoped(std.testing.allocator, "preferences.locale", null);
    defer if (entry) |value| value.deinit(std.testing.allocator);
    try std.testing.expect(entry == null);
}
