//! In-memory memory backend with deterministic native event feed.
//!
//! Pure in-memory store with bounded state and native `events/apply/checkpoint`
//! support. The feed is not durable across process restart, but the runtime
//! contract is native and no longer depends on the generic overlay fallback.

const std = @import("std");
const json_util = @import("../../json_util.zig");
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
    max_entries: usize,
    access_counter: u64,
    instance_id: []const u8,
    owns_instance_id: bool = false,
    events: std.ArrayListUnmanaged(MemoryEvent) = .empty,
    origin_frontiers: std.StringHashMapUnmanaged(u64) = .{},
    scoped_tombstones: std.StringHashMapUnmanaged(EventMeta) = .{},
    key_tombstones: std.StringHashMapUnmanaged(EventMeta) = .{},
    last_sequence: u64 = 0,
    last_timestamp_ms: i64 = 0,
    compacted_through_sequence: u64 = 0,
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
        // Deterministic recency: advances only on writes/apply, never on reads.
        last_access: u64,
        timestamp_ms: i64,
        origin_instance_id: []const u8,
        origin_sequence: u64,
    };

    const EventMeta = struct {
        timestamp_ms: i64,
        origin_instance_id: []const u8,
        origin_sequence: u64,
    };

    const Effect = enum {
        none,
        put,
        delete_scoped,
        delete_all,
    };

    const Decision = struct {
        effect: Effect,
        resolved_state: ?ResolvedMemoryState = null,

        fn deinit(self: *Decision, allocator: std.mem.Allocator) void {
            if (self.resolved_state) |*state| state.deinit(allocator);
        }
    };

    pub fn init(allocator: std.mem.Allocator, max_entries: usize) Self {
        return .{
            .allocator = allocator,
            .entries = .{},
            .max_entries = max_entries,
            .access_counter = 0,
            .instance_id = "",
            .owns_instance_id = false,
        };
    }

    pub fn initWithInstanceId(allocator: std.mem.Allocator, max_entries: usize, instance_id: []const u8) !Self {
        const effective_instance_id = if (instance_id.len > 0) instance_id else "default";
        var self = init(allocator, max_entries);
        self.instance_id = try allocator.dupe(u8, effective_instance_id);
        self.owns_instance_id = true;
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.clearEvents();
        self.clearState();
        if (self.owns_instance_id) self.allocator.free(self.instance_id);
        if (self.owns_self) self.allocator.destroy(self);
    }

    fn clearEvents(self: *Self) void {
        for (self.events.items) |*event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.events = .empty;
    }

    fn clearState(self: *Self) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            self.freeStoredEntry(kv.value_ptr.*);
            self.allocator.free(kv.key_ptr.*);
        }
        self.entries.deinit(self.allocator);
        self.entries = .{};

        var frontier_it = self.origin_frontiers.iterator();
        while (frontier_it.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.origin_frontiers.deinit(self.allocator);
        self.origin_frontiers = .{};

        var scoped_it = self.scoped_tombstones.iterator();
        while (scoped_it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.freeEventMeta(kv.value_ptr.*);
        }
        self.scoped_tombstones.deinit(self.allocator);
        self.scoped_tombstones = .{};

        var key_it = self.key_tombstones.iterator();
        while (key_it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.freeEventMeta(kv.value_ptr.*);
        }
        self.key_tombstones.deinit(self.allocator);
        self.key_tombstones = .{};
    }

    fn freeStoredEntry(self: *Self, entry: StoredEntry) void {
        self.allocator.free(entry.key);
        self.allocator.free(entry.content);
        self.allocator.free(entry.created_at);
        self.allocator.free(entry.updated_at);
        self.allocator.free(entry.origin_instance_id);
        if (entry.session_id) |sid| self.allocator.free(sid);
        switch (entry.category) {
            .custom => |name| self.allocator.free(name),
            else => {},
        }
    }

    fn freeEventMeta(self: *Self, meta: EventMeta) void {
        self.allocator.free(meta.origin_instance_id);
    }

    fn nextWriteOrder(self: *Self) u64 {
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
        if (evict_key) |key| self.removeStorageKey(key);
    }

    fn timestampStringFromMs(self: *Self, timestamp_ms: i64) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{d}", .{@divTrunc(timestamp_ms, 1000)});
    }

    fn dupCategory(self: *Self, cat: MemoryCategory) !MemoryCategory {
        return switch (cat) {
            .custom => |name| .{ .custom = try self.allocator.dupe(u8, name) },
            else => cat,
        };
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

    fn cloneEvent(self: *Self, event: MemoryEvent) !MemoryEvent {
        return .{
            .schema_version = event.schema_version,
            .sequence = event.sequence,
            .origin_instance_id = try self.allocator.dupe(u8, event.origin_instance_id),
            .origin_sequence = event.origin_sequence,
            .timestamp_ms = event.timestamp_ms,
            .operation = event.operation,
            .key = try self.allocator.dupe(u8, event.key),
            .session_id = if (event.session_id) |sid| try self.allocator.dupe(u8, sid) else null,
            .category = if (event.category) |category| try root.cloneMemoryCategory(self.allocator, category) else null,
            .value_kind = event.value_kind,
            .content = if (event.content) |content| try self.allocator.dupe(u8, content) else null,
        };
    }

    fn compareMeta(
        timestamp_ms_a: i64,
        origin_instance_id_a: []const u8,
        origin_sequence_a: u64,
        timestamp_ms_b: i64,
        origin_instance_id_b: []const u8,
        origin_sequence_b: u64,
    ) i8 {
        if (timestamp_ms_a < timestamp_ms_b) return -1;
        if (timestamp_ms_a > timestamp_ms_b) return 1;
        const order = std.mem.order(u8, origin_instance_id_a, origin_instance_id_b);
        if (order == .lt) return -1;
        if (order == .gt) return 1;
        if (origin_sequence_a < origin_sequence_b) return -1;
        if (origin_sequence_a > origin_sequence_b) return 1;
        return 0;
    }

    fn compareInputToMeta(input: MemoryEventInput, meta: EventMeta) i8 {
        return compareMeta(
            input.timestamp_ms,
            input.origin_instance_id,
            input.origin_sequence,
            meta.timestamp_ms,
            meta.origin_instance_id,
            meta.origin_sequence,
        );
    }

    fn compareInputToStored(input: MemoryEventInput, state: StoredEntry) i8 {
        return compareMeta(
            input.timestamp_ms,
            input.origin_instance_id,
            input.origin_sequence,
            state.timestamp_ms,
            state.origin_instance_id,
            state.origin_sequence,
        );
    }

    fn rememberOriginFrontier(self: *Self, origin_instance_id: []const u8, origin_sequence: u64) !void {
        if (self.origin_frontiers.getPtr(origin_instance_id)) |existing| {
            if (origin_sequence > existing.*) existing.* = origin_sequence;
            return;
        }
        try self.origin_frontiers.put(self.allocator, try self.allocator.dupe(u8, origin_instance_id), origin_sequence);
    }

    fn rememberTombstone(
        self: *Self,
        tombstones: *std.StringHashMapUnmanaged(EventMeta),
        key: []const u8,
        input: MemoryEventInput,
    ) !void {
        if (tombstones.getPtr(key)) |existing| {
            if (compareInputToMeta(input, existing.*) <= 0) return;
            self.freeEventMeta(existing.*);
            existing.* = .{
                .timestamp_ms = input.timestamp_ms,
                .origin_instance_id = try self.allocator.dupe(u8, input.origin_instance_id),
                .origin_sequence = input.origin_sequence,
            };
            return;
        }
        try tombstones.put(self.allocator, try self.allocator.dupe(u8, key), .{
            .timestamp_ms = input.timestamp_ms,
            .origin_instance_id = try self.allocator.dupe(u8, input.origin_instance_id),
            .origin_sequence = input.origin_sequence,
        });
    }

    fn removeStorageKey(self: *Self, storage_key: []const u8) void {
        if (self.entries.fetchRemove(storage_key)) |removed| {
            self.freeStoredEntry(removed.value);
            self.allocator.free(removed.key);
        }
    }

    fn hasAnyStateForKey(self: *Self, key: []const u8) bool {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.value_ptr.key, key)) return true;
        }
        return false;
    }

    fn findDefaultStatePtr(self: *Self, key: []const u8) ?*StoredEntry {
        const storage_key = key_codec.encode(self.allocator, key, null) catch return null;
        defer self.allocator.free(storage_key);
        return self.entries.getPtr(storage_key);
    }

    fn makeLocalInput(
        self: *Self,
        operation: MemoryEventOp,
        key: []const u8,
        session_id: ?[]const u8,
        category: ?MemoryCategory,
        value_kind: ?MemoryValueKind,
        content: ?[]const u8,
    ) MemoryEventInput {
        const next_origin_sequence = (self.origin_frontiers.get(self.instance_id) orelse 0) + 1;
        const now_ms = std.time.milliTimestamp();
        const timestamp_ms = if (now_ms > self.last_timestamp_ms) now_ms else self.last_timestamp_ms + 1;
        return .{
            .origin_instance_id = self.instance_id,
            .origin_sequence = next_origin_sequence,
            .timestamp_ms = timestamp_ms,
            .operation = operation,
            .key = key,
            .session_id = session_id,
            .category = category,
            .value_kind = value_kind,
            .content = content,
        };
    }

    fn computeDecision(self: *Self, input: MemoryEventInput) !Decision {
        const storage_key = try key_codec.encode(self.allocator, input.key, input.session_id);
        defer self.allocator.free(storage_key);

        if (self.key_tombstones.getPtr(input.key)) |meta| {
            if (compareInputToMeta(input, meta.*) <= 0) {
                return .{ .effect = .none };
            }
        }
        if (self.scoped_tombstones.getPtr(storage_key)) |meta| {
            if (compareInputToMeta(input, meta.*) <= 0) {
                return .{ .effect = .none };
            }
        }

        switch (input.operation) {
            .put, .merge_object, .merge_string_set => {
                if (self.entries.getPtr(storage_key)) |existing| {
                    if (compareInputToStored(input, existing.*) <= 0) {
                        return .{ .effect = .none };
                    }
                }
                return .{
                    .effect = .put,
                    .resolved_state = try root.resolveMemoryEventState(
                        self.allocator,
                        if (self.entries.getPtr(storage_key)) |existing| existing.content else null,
                        if (self.entries.getPtr(storage_key)) |existing| existing.category else null,
                        if (self.entries.getPtr(storage_key)) |existing| existing.value_kind else null,
                        input,
                    ),
                };
            },
            .delete_scoped => return .{ .effect = .delete_scoped },
            .delete_all => return .{ .effect = .delete_all },
        }
    }

    fn appendEvent(self: *Self, input: MemoryEventInput) !void {
        try self.events.append(self.allocator, .{
            .schema_version = 1,
            .sequence = self.last_sequence + 1,
            .origin_instance_id = try self.allocator.dupe(u8, input.origin_instance_id),
            .origin_sequence = input.origin_sequence,
            .timestamp_ms = input.timestamp_ms,
            .operation = input.operation,
            .key = try self.allocator.dupe(u8, input.key),
            .session_id = if (input.session_id) |sid| try self.allocator.dupe(u8, sid) else null,
            .category = if (input.category) |category| try root.cloneMemoryCategory(self.allocator, category) else null,
            .value_kind = input.value_kind,
            .content = if (input.content) |content| try self.allocator.dupe(u8, content) else null,
        });
        self.last_sequence += 1;
        if (input.timestamp_ms > self.last_timestamp_ms) self.last_timestamp_ms = input.timestamp_ms;
    }

    fn applyDecision(self: *Self, input: MemoryEventInput, decision: *Decision) !void {
        switch (decision.effect) {
            .none => {},
            .put => try self.applyPut(input, decision),
            .delete_scoped => try self.applyScopedDelete(input),
            .delete_all => try self.applyDeleteAll(input),
        }
    }

    fn applyPut(self: *Self, input: MemoryEventInput, decision: *Decision) !void {
        const resolved = decision.resolved_state orelse return error.InvalidEvent;
        const storage_key = try key_codec.encode(self.allocator, input.key, input.session_id);
        defer self.allocator.free(storage_key);

        if (self.scoped_tombstones.getPtr(storage_key)) |meta| {
            if (compareInputToMeta(input, meta.*) > 0) {
                self.freeEventMeta(meta.*);
                if (self.scoped_tombstones.fetchRemove(storage_key)) |removed| self.allocator.free(removed.key);
            }
        }

        const updated_at = try self.timestampStringFromMs(input.timestamp_ms);
        errdefer self.allocator.free(updated_at);

        if (self.entries.getPtr(storage_key)) |existing| {
            self.allocator.free(existing.content);
            existing.content = resolved.content;
            self.allocator.free(existing.updated_at);
            existing.updated_at = updated_at;
            self.allocator.free(existing.origin_instance_id);
            existing.origin_instance_id = try self.allocator.dupe(u8, input.origin_instance_id);
            existing.origin_sequence = input.origin_sequence;
            existing.timestamp_ms = input.timestamp_ms;
            existing.last_access = self.nextWriteOrder();
            existing.value_kind = resolved.value_kind;
            switch (existing.category) {
                .custom => |name| self.allocator.free(name),
                else => {},
            }
            existing.category = resolved.category;
            decision.resolved_state = null;
            return;
        }

        if (self.max_entries == 0) {
            decision.resolved_state = null;
            return;
        }
        if (self.entries.count() >= self.max_entries) self.evictLru();

        const created_at = try self.timestampStringFromMs(input.timestamp_ms);
        errdefer self.allocator.free(created_at);

        try self.entries.put(self.allocator, try self.allocator.dupe(u8, storage_key), .{
            .key = try self.allocator.dupe(u8, input.key),
            .content = resolved.content,
            .category = resolved.category,
            .value_kind = resolved.value_kind,
            .session_id = if (input.session_id) |sid| try self.allocator.dupe(u8, sid) else null,
            .created_at = created_at,
            .updated_at = updated_at,
            .last_access = self.nextWriteOrder(),
            .timestamp_ms = input.timestamp_ms,
            .origin_instance_id = try self.allocator.dupe(u8, input.origin_instance_id),
            .origin_sequence = input.origin_sequence,
        });
        decision.resolved_state = null;
    }

    fn applyScopedDelete(self: *Self, input: MemoryEventInput) !void {
        const storage_key = try key_codec.encode(self.allocator, input.key, input.session_id);
        defer self.allocator.free(storage_key);

        if (self.entries.getPtr(storage_key)) |existing| {
            if (compareInputToStored(input, existing.*) >= 0) {
                self.removeStorageKey(storage_key);
            }
        }
        try self.rememberTombstone(&self.scoped_tombstones, storage_key, input);
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
            if (compareInputToStored(input, kv.value_ptr.*) >= 0) {
                try to_remove.append(self.allocator, try self.allocator.dupe(u8, kv.key_ptr.*));
            }
        }
        for (to_remove.items) |storage_key| self.removeStorageKey(storage_key);
        try self.rememberTombstone(&self.key_tombstones, input.key, input);
    }

    fn recordInput(self: *Self, input: MemoryEventInput) !bool {
        const frontier = self.origin_frontiers.get(input.origin_instance_id) orelse 0;
        if (input.origin_sequence <= frontier) return false;

        var decision = try self.computeDecision(input);
        defer decision.deinit(self.allocator);

        try self.appendEvent(input);
        try self.rememberOriginFrontier(input.origin_instance_id, input.origin_sequence);
        try self.applyDecision(input, &decision);
        return true;
    }

    fn storeLocal(self: *Self, key: []const u8, content: []const u8, category: MemoryCategory, session_id: ?[]const u8) !void {
        _ = try self.recordInput(self.makeLocalInput(.put, key, session_id, category, null, content));
    }

    fn deleteLocalKey(self: *Self, key: []const u8) !bool {
        const had_entry = self.hasAnyStateForKey(key);
        _ = try self.recordInput(self.makeLocalInput(.delete_all, key, null, null, null, null));
        return had_entry;
    }

    fn deleteLocalScoped(self: *Self, key: []const u8, session_id: ?[]const u8) !bool {
        const storage_key = try key_codec.encode(self.allocator, key, session_id);
        defer self.allocator.free(storage_key);
        const had_entry = self.entries.contains(storage_key);
        _ = try self.recordInput(self.makeLocalInput(.delete_scoped, key, session_id, null, null, null));
        return had_entry;
    }

    fn listEventsAfter(self: *Self, allocator: std.mem.Allocator, after_sequence: u64, limit: usize) ![]MemoryEvent {
        if (after_sequence < self.compacted_through_sequence) return error.CursorExpired;
        if (limit == 0) return allocator.alloc(MemoryEvent, 0);

        var out: std.ArrayListUnmanaged(MemoryEvent) = .empty;
        errdefer {
            for (out.items) |*event| event.deinit(allocator);
            out.deinit(allocator);
        }
        for (self.events.items) |event| {
            if (event.sequence <= after_sequence) continue;
            if (out.items.len >= limit) break;
            try out.append(allocator, .{
                .schema_version = event.schema_version,
                .sequence = event.sequence,
                .origin_instance_id = try allocator.dupe(u8, event.origin_instance_id),
                .origin_sequence = event.origin_sequence,
                .timestamp_ms = event.timestamp_ms,
                .operation = event.operation,
                .key = try allocator.dupe(u8, event.key),
                .session_id = if (event.session_id) |sid| try allocator.dupe(u8, sid) else null,
                .category = if (event.category) |category| try root.cloneMemoryCategory(allocator, category) else null,
                .value_kind = event.value_kind,
                .content = if (event.content) |content| try allocator.dupe(u8, content) else null,
            });
        }
        return out.toOwnedSlice(allocator);
    }

    fn compactEventsInternal(self: *Self) !u64 {
        self.compacted_through_sequence = self.last_sequence;
        self.clearEvents();
        return self.compacted_through_sequence;
    }

    fn cloneStateEntry(self: *Self, allocator: std.mem.Allocator, state: StoredEntry) !MemoryEntry {
        _ = self;
        return cloneEntry(allocator, state);
    }

    fn listCanonical(self: *Self, allocator: std.mem.Allocator, category: ?MemoryCategory, session_id: ?[]const u8) ![]MemoryEntry {
        var results: std.ArrayList(MemoryEntry) = .empty;
        errdefer {
            for (results.items) |*e| e.deinit(allocator);
            results.deinit(allocator);
        }

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            if (category) |cat| {
                if (!e.category.eql(cat)) continue;
            }
            if (session_id) |filter_sid| {
                if (e.session_id) |esid| {
                    if (!std.mem.eql(u8, esid, filter_sid)) continue;
                } else continue;
            }
            try results.append(allocator, try cloneEntry(allocator, e));
        }
        return results.toOwnedSlice(allocator);
    }

    fn recallCanonical(self: *Self, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) ![]MemoryEntry {
        const Pair = struct { entry: StoredEntry };
        var matches: std.ArrayList(Pair) = .empty;
        defer matches.deinit(allocator);

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            if (session_id) |filter_sid| {
                if (e.session_id) |esid| {
                    if (!std.mem.eql(u8, esid, filter_sid)) continue;
                } else continue;
            }
            if (std.mem.indexOf(u8, e.key, query) != null or
                std.mem.indexOf(u8, e.content, query) != null)
            {
                try matches.append(allocator, .{ .entry = e });
            }
        }

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
            slot.* = try cloneEntry(allocator, matches.items[i].entry);
            filled += 1;
        }
        return results;
    }

    fn appendCheckpointMetaLine(self: *Self, out: *std.ArrayListUnmanaged(u8)) !void {
        try out.append(self.allocator, '{');
        try json_util.appendJsonKeyValue(out, self.allocator, "kind", "meta");
        try out.append(self.allocator, ',');
        try json_util.appendJsonInt(out, self.allocator, "schema_version", 1);
        try out.append(self.allocator, ',');
        try json_util.appendJsonKey(out, self.allocator, "last_sequence");
        try out.writer(self.allocator).print("{d}", .{self.last_sequence});
        try out.append(self.allocator, ',');
        try json_util.appendJsonKey(out, self.allocator, "last_timestamp_ms");
        try out.writer(self.allocator).print("{d}", .{self.last_timestamp_ms});
        try out.append(self.allocator, ',');
        try json_util.appendJsonKey(out, self.allocator, "compacted_through_sequence");
        try out.writer(self.allocator).print("{d}", .{self.compacted_through_sequence});
        try out.appendSlice(self.allocator, "}\n");
    }

    fn appendCheckpointFrontierLine(self: *Self, out: *std.ArrayListUnmanaged(u8), origin_instance_id: []const u8, origin_sequence: u64) !void {
        try out.append(self.allocator, '{');
        try json_util.appendJsonKeyValue(out, self.allocator, "kind", "frontier");
        try out.append(self.allocator, ',');
        try json_util.appendJsonKeyValue(out, self.allocator, "origin_instance_id", origin_instance_id);
        try out.append(self.allocator, ',');
        try json_util.appendJsonKey(out, self.allocator, "origin_sequence");
        try out.writer(self.allocator).print("{d}", .{origin_sequence});
        try out.appendSlice(self.allocator, "}\n");
    }

    fn appendCheckpointStateLine(self: *Self, out: *std.ArrayListUnmanaged(u8), state: StoredEntry) !void {
        try out.append(self.allocator, '{');
        try json_util.appendJsonKeyValue(out, self.allocator, "kind", "state");
        try out.append(self.allocator, ',');
        try json_util.appendJsonKeyValue(out, self.allocator, "key", state.key);
        try out.append(self.allocator, ',');
        try json_util.appendJsonKey(out, self.allocator, "session_id");
        if (state.session_id) |sid| {
            try json_util.appendJsonString(out, self.allocator, sid);
        } else {
            try out.appendSlice(self.allocator, "null");
        }
        try out.append(self.allocator, ',');
        try json_util.appendJsonKeyValue(out, self.allocator, "category", state.category.toString());
        try out.append(self.allocator, ',');
        try json_util.appendJsonKey(out, self.allocator, "value_kind");
        if (state.value_kind) |kind| {
            try json_util.appendJsonString(out, self.allocator, kind.toString());
        } else {
            try out.appendSlice(self.allocator, "null");
        }
        try out.append(self.allocator, ',');
        try json_util.appendJsonKeyValue(out, self.allocator, "content", state.content);
        try out.append(self.allocator, ',');
        try json_util.appendJsonKey(out, self.allocator, "timestamp_ms");
        try out.writer(self.allocator).print("{d}", .{state.timestamp_ms});
        try out.append(self.allocator, ',');
        try json_util.appendJsonKeyValue(out, self.allocator, "origin_instance_id", state.origin_instance_id);
        try out.append(self.allocator, ',');
        try json_util.appendJsonKey(out, self.allocator, "origin_sequence");
        try out.writer(self.allocator).print("{d}", .{state.origin_sequence});
        try out.appendSlice(self.allocator, "}\n");
    }

    fn appendCheckpointTombstoneLine(self: *Self, out: *std.ArrayListUnmanaged(u8), kind: []const u8, key: []const u8, meta: EventMeta) !void {
        try out.append(self.allocator, '{');
        try json_util.appendJsonKeyValue(out, self.allocator, "kind", kind);
        try out.append(self.allocator, ',');
        try json_util.appendJsonKeyValue(out, self.allocator, "key", key);
        try out.append(self.allocator, ',');
        try json_util.appendJsonKey(out, self.allocator, "timestamp_ms");
        try out.writer(self.allocator).print("{d}", .{meta.timestamp_ms});
        try out.append(self.allocator, ',');
        try json_util.appendJsonKeyValue(out, self.allocator, "origin_instance_id", meta.origin_instance_id);
        try out.append(self.allocator, ',');
        try json_util.appendJsonKey(out, self.allocator, "origin_sequence");
        try out.writer(self.allocator).print("{d}", .{meta.origin_sequence});
        try out.appendSlice(self.allocator, "}\n");
    }

    fn collectSortedStringKeys(
        self: *Self,
        comptime T: type,
        map: *const std.StringHashMapUnmanaged(T),
    ) ![][]const u8 {
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer keys.deinit(self.allocator);
        var it = map.iterator();
        while (it.next()) |kv| try keys.append(self.allocator, kv.key_ptr.*);
        std.mem.sort([]const u8, keys.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        return keys.toOwnedSlice(self.allocator);
    }

    fn serializeCheckpointPayload(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);

        try self.appendCheckpointMetaLine(&out);

        const frontier_keys = try self.collectSortedStringKeys(u64, &self.origin_frontiers);
        defer self.allocator.free(frontier_keys);
        for (frontier_keys) |origin_instance_id| {
            try self.appendCheckpointFrontierLine(&out, origin_instance_id, self.origin_frontiers.get(origin_instance_id).?);
        }

        const state_keys = try self.collectSortedStringKeys(StoredEntry, &self.entries);
        defer self.allocator.free(state_keys);
        for (state_keys) |storage_key| {
            try self.appendCheckpointStateLine(&out, self.entries.get(storage_key).?);
        }

        const scoped_keys = try self.collectSortedStringKeys(EventMeta, &self.scoped_tombstones);
        defer self.allocator.free(scoped_keys);
        for (scoped_keys) |storage_key| {
            try self.appendCheckpointTombstoneLine(&out, "scoped_tombstone", storage_key, self.scoped_tombstones.get(storage_key).?);
        }

        const key_keys = try self.collectSortedStringKeys(EventMeta, &self.key_tombstones);
        defer self.allocator.free(key_keys);
        for (key_keys) |key| {
            try self.appendCheckpointTombstoneLine(&out, "key_tombstone", key, self.key_tombstones.get(key).?);
        }

        const owned = try allocator.dupe(u8, out.items);
        out.deinit(self.allocator);
        return owned;
    }

    fn jsonStringField(value: std.json.Value, key: []const u8) ?[]const u8 {
        if (value != .object) return null;
        const field = value.object.get(key) orelse return null;
        return if (field == .string) field.string else null;
    }

    fn jsonNullableStringField(value: std.json.Value, key: []const u8) ?[]const u8 {
        if (value != .object) return null;
        const field = value.object.get(key) orelse return null;
        return switch (field) {
            .null => null,
            .string => field.string,
            else => null,
        };
    }

    fn jsonUnsignedField(value: std.json.Value, key: []const u8) ?u64 {
        if (value != .object) return null;
        const field = value.object.get(key) orelse return null;
        return switch (field) {
            .integer => |v| if (v >= 0) @intCast(v) else null,
            .number_string => |v| std.fmt.parseInt(u64, v, 10) catch null,
            else => null,
        };
    }

    fn jsonIntegerField(value: std.json.Value, key: []const u8) ?i64 {
        if (value != .object) return null;
        const field = value.object.get(key) orelse return null;
        return switch (field) {
            .integer => |v| v,
            .number_string => |v| std.fmt.parseInt(i64, v, 10) catch null,
            else => null,
        };
    }

    fn restoreCheckpointState(
        self: *Self,
        key: []const u8,
        session_id: ?[]const u8,
        category: MemoryCategory,
        value_kind: ?MemoryValueKind,
        content: []const u8,
        timestamp_ms: i64,
        origin_instance_id: []const u8,
        origin_sequence: u64,
    ) !void {
        const storage_key = try key_codec.encode(self.allocator, key, session_id);
        defer self.allocator.free(storage_key);
        const created_at = try self.timestampStringFromMs(timestamp_ms);
        errdefer self.allocator.free(created_at);
        const updated_at = try self.timestampStringFromMs(timestamp_ms);
        errdefer self.allocator.free(updated_at);

        try self.entries.put(self.allocator, try self.allocator.dupe(u8, storage_key), .{
            .key = try self.allocator.dupe(u8, key),
            .content = try self.allocator.dupe(u8, content),
            .category = category,
            .value_kind = value_kind,
            .session_id = if (session_id) |sid| try self.allocator.dupe(u8, sid) else null,
            .created_at = created_at,
            .updated_at = updated_at,
            .last_access = 0,
            .timestamp_ms = timestamp_ms,
            .origin_instance_id = try self.allocator.dupe(u8, origin_instance_id),
            .origin_sequence = origin_sequence,
        });
    }

    fn restoreCheckpointTombstone(
        self: *Self,
        tombstones: *std.StringHashMapUnmanaged(EventMeta),
        key: []const u8,
        timestamp_ms: i64,
        origin_instance_id: []const u8,
        origin_sequence: u64,
    ) !void {
        try tombstones.put(self.allocator, try self.allocator.dupe(u8, key), .{
            .timestamp_ms = timestamp_ms,
            .origin_instance_id = try self.allocator.dupe(u8, origin_instance_id),
            .origin_sequence = origin_sequence,
        });
    }

    fn recomputeWriteOrderFromState(self: *Self) !void {
        const EntryRef = struct {
            storage_key: []const u8,
            timestamp_ms: i64,
            origin_instance_id: []const u8,
            origin_sequence: u64,
        };
        var refs: std.ArrayListUnmanaged(EntryRef) = .empty;
        defer refs.deinit(self.allocator);

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            try refs.append(self.allocator, .{
                .storage_key = kv.key_ptr.*,
                .timestamp_ms = kv.value_ptr.timestamp_ms,
                .origin_instance_id = kv.value_ptr.origin_instance_id,
                .origin_sequence = kv.value_ptr.origin_sequence,
            });
        }
        std.mem.sort(EntryRef, refs.items, {}, struct {
            fn lessThan(_: void, a: EntryRef, b: EntryRef) bool {
                const cmp = compareMeta(
                    a.timestamp_ms,
                    a.origin_instance_id,
                    a.origin_sequence,
                    b.timestamp_ms,
                    b.origin_instance_id,
                    b.origin_sequence,
                );
                return cmp == -1;
            }
        }.lessThan);

        self.access_counter = 0;
        for (refs.items) |ref| {
            if (self.entries.getPtr(ref.storage_key)) |entry| {
                self.access_counter += 1;
                entry.last_access = self.access_counter;
            }
        }
    }

    fn applyCheckpointPayload(self: *Self, payload: []const u8) !void {
        var scratch = try Self.initWithInstanceId(self.allocator, self.max_entries, self.instance_id);
        defer scratch.deinit();

        var saw_meta = false;
        var lines = std.mem.splitScalar(u8, payload, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r\n");
            if (line.len == 0) continue;

            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, line, .{});
            defer parsed.deinit();

            const kind = jsonStringField(parsed.value, "kind") orelse return error.InvalidEvent;
            if (std.mem.eql(u8, kind, "meta")) {
                const schema_version = jsonUnsignedField(parsed.value, "schema_version") orelse return error.InvalidEvent;
                if (schema_version != 1) return error.InvalidEvent;
                scratch.last_sequence = jsonUnsignedField(parsed.value, "last_sequence") orelse 0;
                scratch.last_timestamp_ms = jsonIntegerField(parsed.value, "last_timestamp_ms") orelse 0;
                scratch.compacted_through_sequence = jsonUnsignedField(parsed.value, "compacted_through_sequence") orelse scratch.last_sequence;
                saw_meta = true;
                continue;
            }
            if (std.mem.eql(u8, kind, "frontier")) {
                const origin_instance_id = jsonStringField(parsed.value, "origin_instance_id") orelse return error.InvalidEvent;
                const origin_sequence = jsonUnsignedField(parsed.value, "origin_sequence") orelse return error.InvalidEvent;
                try scratch.rememberOriginFrontier(origin_instance_id, origin_sequence);
                continue;
            }
            if (std.mem.eql(u8, kind, "state")) {
                const key = jsonStringField(parsed.value, "key") orelse return error.InvalidEvent;
                const content = jsonStringField(parsed.value, "content") orelse return error.InvalidEvent;
                const category_name = jsonStringField(parsed.value, "category") orelse return error.InvalidEvent;
                const category = try scratch.dupCategory(MemoryCategory.fromString(category_name));
                errdefer switch (category) {
                    .custom => |name| scratch.allocator.free(name),
                    else => {},
                };
                const value_kind = if (jsonNullableStringField(parsed.value, "value_kind")) |kind_name|
                    MemoryValueKind.fromString(kind_name) orelse return error.InvalidEvent
                else
                    null;
                const timestamp_ms = jsonIntegerField(parsed.value, "timestamp_ms") orelse return error.InvalidEvent;
                const origin_instance_id = jsonStringField(parsed.value, "origin_instance_id") orelse return error.InvalidEvent;
                const origin_sequence = jsonUnsignedField(parsed.value, "origin_sequence") orelse return error.InvalidEvent;
                try scratch.restoreCheckpointState(
                    key,
                    jsonNullableStringField(parsed.value, "session_id"),
                    category,
                    value_kind,
                    content,
                    timestamp_ms,
                    origin_instance_id,
                    origin_sequence,
                );
                continue;
            }
            if (std.mem.eql(u8, kind, "scoped_tombstone")) {
                const key = jsonStringField(parsed.value, "key") orelse return error.InvalidEvent;
                const timestamp_ms = jsonIntegerField(parsed.value, "timestamp_ms") orelse return error.InvalidEvent;
                const origin_instance_id = jsonStringField(parsed.value, "origin_instance_id") orelse return error.InvalidEvent;
                const origin_sequence = jsonUnsignedField(parsed.value, "origin_sequence") orelse return error.InvalidEvent;
                try scratch.restoreCheckpointTombstone(&scratch.scoped_tombstones, key, timestamp_ms, origin_instance_id, origin_sequence);
                continue;
            }
            if (std.mem.eql(u8, kind, "key_tombstone")) {
                const key = jsonStringField(parsed.value, "key") orelse return error.InvalidEvent;
                const timestamp_ms = jsonIntegerField(parsed.value, "timestamp_ms") orelse return error.InvalidEvent;
                const origin_instance_id = jsonStringField(parsed.value, "origin_instance_id") orelse return error.InvalidEvent;
                const origin_sequence = jsonUnsignedField(parsed.value, "origin_sequence") orelse return error.InvalidEvent;
                try scratch.restoreCheckpointTombstone(&scratch.key_tombstones, key, timestamp_ms, origin_instance_id, origin_sequence);
                continue;
            }
            return error.InvalidEvent;
        }
        if (!saw_meta) return error.InvalidEvent;

        self.clearEvents();
        self.clearState();
        self.last_sequence = scratch.last_sequence;
        self.last_timestamp_ms = scratch.last_timestamp_ms;
        self.compacted_through_sequence = scratch.compacted_through_sequence;
        self.events = scratch.events;
        self.entries = scratch.entries;
        self.origin_frontiers = scratch.origin_frontiers;
        self.scoped_tombstones = scratch.scoped_tombstones;
        self.key_tombstones = scratch.key_tombstones;
        scratch.events = .empty;
        scratch.entries = .{};
        scratch.origin_frontiers = .{};
        scratch.scoped_tombstones = .{};
        scratch.key_tombstones = .{};
        try self.recomputeWriteOrderFromState();
    }

    // ── vtable impl fns ────────────────────────────────────────────

    fn implName(_: *anyopaque) []const u8 {
        return "memory_lru";
    }

    fn implStore(ptr: *anyopaque, key: []const u8, content: []const u8, category: MemoryCategory, session_id: ?[]const u8) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.storeLocal(key, content, category, session_id);
    }

    fn implRecall(ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        return self_.recallCanonical(allocator, query, limit, session_id);
    }

    fn implGet(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        const entry_ptr = self_.findDefaultStatePtr(key) orelse return null;
        return try self_.cloneStateEntry(allocator, entry_ptr.*);
    }

    fn implGetScoped(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8) anyerror!?MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        const storage_key = try key_codec.encode(allocator, key, session_id);
        defer allocator.free(storage_key);
        const entry_ptr = self_.entries.getPtr(storage_key) orelse return null;
        return try self_.cloneStateEntry(allocator, entry_ptr.*);
    }

    fn implList(ptr: *anyopaque, allocator: std.mem.Allocator, category: ?MemoryCategory, session_id: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        return self_.listCanonical(allocator, category, session_id);
    }

    fn implForget(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        return self_.deleteLocalKey(key);
    }

    fn implForgetScoped(ptr: *anyopaque, key: []const u8, session_id: ?[]const u8) anyerror!bool {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        return self_.deleteLocalScoped(key, session_id);
    }

    fn implListEvents(ptr: *anyopaque, allocator: std.mem.Allocator, after_sequence: u64, limit: usize) anyerror![]MemoryEvent {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        return self_.listEventsAfter(allocator, after_sequence, limit);
    }

    fn implApplyEvent(ptr: *anyopaque, input: MemoryEventInput) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        _ = try self_.recordInput(input);
    }

    fn implLastEventSequence(ptr: *anyopaque) anyerror!u64 {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        return self_.last_sequence;
    }

    fn implEventFeedInfo(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!MemoryEventFeedInfo {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        return .{
            .instance_id = try allocator.dupe(u8, self_.instance_id),
            .last_sequence = self_.last_sequence,
            .next_local_origin_sequence = (self_.origin_frontiers.get(self_.instance_id) orelse 0) + 1,
            .supports_compaction = true,
            .storage_kind = .native,
            .journal_path = null,
            .checkpoint_path = null,
            .compacted_through_sequence = self_.compacted_through_sequence,
            .oldest_available_sequence = self_.compacted_through_sequence + 1,
        };
    }

    fn implCompactEvents(ptr: *anyopaque) anyerror!u64 {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        return self_.compactEventsInternal();
    }

    fn implExportCheckpoint(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        return self_.serializeCheckpointPayload(allocator);
    }

    fn implApplyCheckpoint(ptr: *anyopaque, payload: []const u8) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.applyCheckpointPayload(payload);
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
        .exportCheckpoint = &implExportCheckpoint,
        .applyCheckpoint = &implApplyCheckpoint,
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
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 10, "agent-a");
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
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("greeting", "hello world", .core, null);
    try std.testing.expectEqual(@as(usize, 1), try m.count());

    {
        const entry = (try m.get(std.testing.allocator, "greeting")).?;
        defer entry.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("greeting", entry.key);
        try std.testing.expectEqualStrings("hello world", entry.content);
        try std.testing.expect(entry.category.eql(.core));
    }

    {
        const results = try m.recall(std.testing.allocator, "hello", 10, null);
        defer root.freeEntries(std.testing.allocator, results);
        try std.testing.expectEqual(@as(usize, 1), results.len);
        try std.testing.expectEqualStrings("hello world", results[0].content);
    }

    const forgotten = try m.forget("greeting");
    try std.testing.expect(forgotten);
    try std.testing.expectEqual(@as(usize, 0), try m.count());

    const forgotten2 = try m.forget("greeting");
    try std.testing.expect(!forgotten2);
}

test "update existing key within same namespace" {
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
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

test "LRU eviction: oldest written entry evicted at capacity" {
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 3, "agent-a");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "first", .core, null);
    try m.store("b", "second", .core, null);
    try m.store("c", "third", .core, null);
    try std.testing.expectEqual(@as(usize, 3), try m.count());

    try m.store("d", "fourth", .core, null);
    try std.testing.expectEqual(@as(usize, 3), try m.count());

    const got_a = try m.get(std.testing.allocator, "a");
    try std.testing.expect(got_a == null);

    const got_d = (try m.get(std.testing.allocator, "d")).?;
    defer got_d.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("fourth", got_d.content);
}

test "eviction order stays deterministic across reads" {
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 3, "agent-a");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "first", .core, null);
    try m.store("b", "second", .core, null);
    try m.store("c", "third", .core, null);

    {
        const entry = (try m.get(std.testing.allocator, "a")).?;
        defer entry.deinit(std.testing.allocator);
    }

    try m.store("d", "fourth", .core, null);
    try std.testing.expectEqual(@as(usize, 3), try m.count());

    const got_a = try m.get(std.testing.allocator, "a");
    try std.testing.expect(got_a == null);

    const got_b = (try m.get(std.testing.allocator, "b")).?;
    defer got_b.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("second", got_b.content);
}

test "recall with substring matching" {
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("user_pref", "dark mode enabled", .core, null);
    try m.store("api_key", "sk-12345", .core, null);
    try m.store("note", "remember to buy milk", .daily, null);

    {
        const results = try m.recall(std.testing.allocator, "mode", 10, null);
        defer root.freeEntries(std.testing.allocator, results);
        try std.testing.expectEqual(@as(usize, 1), results.len);
        try std.testing.expectEqualStrings("user_pref", results[0].key);
    }

    {
        const results = try m.recall(std.testing.allocator, "key", 10, null);
        defer root.freeEntries(std.testing.allocator, results);
        try std.testing.expectEqual(@as(usize, 1), results.len);
        try std.testing.expectEqualStrings("api_key", results[0].key);
    }

    {
        const results = try m.recall(std.testing.allocator, "e", 10, null);
        defer root.freeEntries(std.testing.allocator, results);
        try std.testing.expectEqual(@as(usize, 3), results.len);
    }
}

test "recall with session_id filter" {
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k1", "data for session A", .core, "sess-A");
    try m.store("k2", "data for session B", .core, "sess-B");
    try m.store("k3", "data no session", .core, null);

    {
        const results = try m.recall(std.testing.allocator, "data", 10, "sess-A");
        defer root.freeEntries(std.testing.allocator, results);
        try std.testing.expectEqual(@as(usize, 1), results.len);
        try std.testing.expectEqualStrings("k1", results[0].key);
    }

    {
        const results = try m.recall(std.testing.allocator, "data", 10, null);
        defer root.freeEntries(std.testing.allocator, results);
        try std.testing.expectEqual(@as(usize, 3), results.len);
    }
}

test "list by category filter" {
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("core1", "c1", .core, null);
    try m.store("core2", "c2", .core, null);
    try m.store("daily1", "d1", .daily, null);
    try m.store("conv1", "v1", .conversation, null);

    {
        const results = try m.list(std.testing.allocator, .core, null);
        defer root.freeEntries(std.testing.allocator, results);
        try std.testing.expectEqual(@as(usize, 2), results.len);
    }

    {
        const results = try m.list(std.testing.allocator, .daily, null);
        defer root.freeEntries(std.testing.allocator, results);
        try std.testing.expectEqual(@as(usize, 1), results.len);
    }

    {
        const results = try m.list(std.testing.allocator, null, null);
        defer root.freeEntries(std.testing.allocator, results);
        try std.testing.expectEqual(@as(usize, 4), results.len);
    }
}

test "count accuracy after store/forget" {
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
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
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
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
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
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

test "get ignores scoped-only entries in LRU" {
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("shared", "scoped", .core, "sess-a");
    try std.testing.expect((try m.get(std.testing.allocator, "shared")) == null);
}

test "forgetScoped removes only matching namespace in LRU" {
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
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
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
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
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k", "v", .{ .custom = "my_cat" }, null);
    const entry = (try m.get(std.testing.allocator, "k")).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("my_cat", entry.category.custom);
}

test "LRU store and get with empty key" {
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
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
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("k", "", .core, null);
    const entry = (try m.get(std.testing.allocator, "k")).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", entry.content);
}

test "LRU store with special chars in key and content" {
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
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
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "alpha", .core, null);
    try m.store("b", "beta", .core, null);

    const results = try m.recall(std.testing.allocator, "", 10, null);
    defer root.freeEntries(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "LRU same key supports null and value session_id" {
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
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
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
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
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
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
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
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

test "LRU recall returns most recently written first" {
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "common", .core, null);
    try m.store("b", "common", .core, null);
    try m.store("c", "common", .core, null);
    try m.store("a", "common", .core, null);

    const results = try m.recall(std.testing.allocator, "common", 10, null);
    defer root.freeEntries(std.testing.allocator, results);
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("a", results[0].key);
}

test "LRU recall with session_id returns only matching" {
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
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
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "exists", .core, null);
    const result = try m.forget("nonexistent");
    try std.testing.expect(!result);
    try std.testing.expectEqual(@as(usize, 1), try m.count());
}

test "LRU get on nonexistent key does not increment access counter" {
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 3, "agent-a");
    defer mem.deinit();
    const m = mem.memory();

    try std.testing.expectEqual(@as(u64, 0), mem.access_counter);

    const result = try m.get(std.testing.allocator, "nonexistent");
    try std.testing.expect(result == null);

    try std.testing.expectEqual(@as(u64, 0), mem.access_counter);
}

test "LRU eviction with capacity 1" {
    var mem = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 1, "agent-a");
    defer mem.deinit();
    const m = mem.memory();

    try m.store("a", "first", .core, null);
    try std.testing.expectEqual(@as(usize, 1), try m.count());

    try m.store("b", "second", .core, null);
    try std.testing.expectEqual(@as(usize, 1), try m.count());

    const got_a = try m.get(std.testing.allocator, "a");
    try std.testing.expect(got_a == null);

    const got_b = (try m.get(std.testing.allocator, "b")).?;
    defer got_b.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("second", got_b.content);
}

test "memory_lru native feed roundtrip applies events" {
    var source = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
    defer source.deinit();
    var replica = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-b");
    defer replica.deinit();
    var source_mem = source.memory();
    var replica_mem = replica.memory();

    try source_mem.store("preferences.theme", "dark", .{ .custom = "preferences" }, null);
    try source_mem.applyEvent(.{
        .origin_instance_id = "agent-a",
        .origin_sequence = 2,
        .timestamp_ms = std.time.milliTimestamp(),
        .operation = .merge_string_set,
        .key = "traits.tags",
        .session_id = null,
        .category = .{ .custom = "traits" },
        .value_kind = .string_set,
        .content = "[\"precise\"]",
    });

    const events = try source_mem.listEvents(std.testing.allocator, 0, 16);
    defer root.freeEvents(std.testing.allocator, events);
    try std.testing.expect(events.len >= 2);
    for (events) |event| {
        try replica_mem.applyEvent(.{
            .origin_instance_id = event.origin_instance_id,
            .origin_sequence = event.origin_sequence,
            .timestamp_ms = event.timestamp_ms,
            .operation = event.operation,
            .key = event.key,
            .session_id = event.session_id,
            .category = event.category,
            .value_kind = event.value_kind,
            .content = event.content,
        });
    }

    const pref = (try replica_mem.get(std.testing.allocator, "preferences.theme")).?;
    defer pref.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dark", pref.content);

    const traits = (try replica_mem.get(std.testing.allocator, "traits.tags")).?;
    defer traits.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("[\"precise\"]", traits.content);
}

test "memory_lru compact and checkpoint restore preserve sequence continuity" {
    var source = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
    defer source.deinit();
    var source_mem = source.memory();

    try source_mem.store("alpha", "one", .core, null);
    try source_mem.store("beta", "two", .conversation, "sess-a");

    const compacted = try source_mem.compactEvents();
    try std.testing.expect(compacted > 0);
    try std.testing.expectError(error.CursorExpired, source_mem.listEvents(std.testing.allocator, 0, 8));

    const checkpoint = try source_mem.exportCheckpoint(std.testing.allocator);
    defer std.testing.allocator.free(checkpoint);

    var replica = try InMemoryLruMemory.initWithInstanceId(std.testing.allocator, 100, "agent-a");
    defer replica.deinit();
    var replica_mem = replica.memory();
    try replica_mem.applyCheckpoint(checkpoint);

    const info = try replica_mem.eventFeedInfo(std.testing.allocator);
    defer info.deinit(std.testing.allocator);
    try std.testing.expectEqual(compacted, info.compacted_through_sequence);
    try std.testing.expectEqual(compacted + 1, info.next_local_origin_sequence);

    try replica_mem.store("gamma", "three", .daily, null);
    const tail = try replica_mem.listEvents(std.testing.allocator, compacted, 8);
    defer root.freeEvents(std.testing.allocator, tail);
    try std.testing.expectEqual(@as(usize, 1), tail.len);
    try std.testing.expectEqualStrings("gamma", tail[0].key);
    try std.testing.expectEqual(compacted + 1, tail[0].origin_sequence);
}
