const std = @import("std");
const fs_compat = @import("../fs_compat.zig");
const json_util = @import("../json_util.zig");
const root = @import("root.zig");
const key_codec = @import("vector/key_codec.zig");

const Memory = root.Memory;
const MemoryCategory = root.MemoryCategory;
const MemoryEntry = root.MemoryEntry;
const MemoryEvent = root.MemoryEvent;
const MemoryEventFeedInfo = root.MemoryEventFeedInfo;
const MemoryEventInput = root.MemoryEventInput;

const MAX_EVENT_LINE_BYTES: usize = 1024 * 1024;

pub const EventFeedOverlay = struct {
    allocator: std.mem.Allocator,
    backend: Memory,
    journal_path: []u8,
    instance_id: []u8,
    last_sequence: u64 = 0,
    last_timestamp_ms: i64 = 0,
    loaded_size_bytes: u64 = 0,
    projection_offset_bytes: u64 = 0,
    origin_frontiers: std.StringHashMapUnmanaged(u64) = .{},
    state_meta: std.StringHashMapUnmanaged(EventMeta) = .{},
    scoped_tombstones: std.StringHashMapUnmanaged(EventMeta) = .{},
    key_tombstones: std.StringHashMapUnmanaged(EventMeta) = .{},
    owns_self: bool = false,

    const Self = @This();

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

        fn toString(self: Effect) []const u8 {
            return switch (self) {
                .none => "none",
                .put => "put",
                .delete_scoped => "delete_scoped",
                .delete_all => "delete_all",
            };
        }

        fn fromString(value: []const u8) ?Effect {
            if (std.mem.eql(u8, value, "none")) return .none;
            if (std.mem.eql(u8, value, "put")) return .put;
            if (std.mem.eql(u8, value, "delete_scoped")) return .delete_scoped;
            if (std.mem.eql(u8, value, "delete_all")) return .delete_all;
            return null;
        }
    };

    const BootstrapEntry = struct {
        key: []const u8,
        content: []const u8,
        category: MemoryCategory,
        session_id: ?[]const u8,
    };

    const RecordedEvent = struct {
        event: MemoryEvent,
        effect: ?Effect = null,

        fn deinit(self: *RecordedEvent, allocator: std.mem.Allocator) void {
            self.event.deinit(allocator);
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        backend: Memory,
        journal_root_dir: []const u8,
        journal_identity: []const u8,
        instance_id: []const u8,
    ) !Self {
        const effective_instance_id = if (instance_id.len > 0) instance_id else "default";
        const journal_path = try buildJournalPath(allocator, journal_root_dir, journal_identity);
        errdefer allocator.free(journal_path);

        var self = Self{
            .allocator = allocator,
            .backend = backend,
            .journal_path = journal_path,
            .instance_id = try allocator.dupe(u8, effective_instance_id),
        };
        errdefer self.deinitMembers();

        try ensureJournalParent(journal_path);

        var file = try self.openJournalExclusive();
        defer file.close();

        try self.refreshJournalLocked(&file);
        if (self.last_sequence == 0) {
            try self.bootstrapFromBackendLocked(&file);
        }
        try self.replayProjectionLocked(&file);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.deinitMembers();
        self.backend.deinit();
        if (self.owns_self) self.allocator.destroy(self);
    }

    fn deinitMembers(self: *Self) void {
        self.allocator.free(self.journal_path);
        self.allocator.free(self.instance_id);
        self.clearJournalState();
    }

    fn clearJournalState(self: *Self) void {
        self.last_sequence = 0;
        self.last_timestamp_ms = 0;
        self.loaded_size_bytes = 0;
        self.projection_offset_bytes = 0;

        var frontier_it = self.origin_frontiers.iterator();
        while (frontier_it.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.origin_frontiers.deinit(self.allocator);
        self.origin_frontiers = .{};

        var state_it = self.state_meta.iterator();
        while (state_it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.freeEventMeta(kv.value_ptr.*);
        }
        self.state_meta.deinit(self.allocator);
        self.state_meta = .{};

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

    pub fn memory(self: *Self) Memory {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn implName(ptr: *anyopaque) []const u8 {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        return self_.backend.name();
    }

    fn implStore(ptr: *anyopaque, key: []const u8, content: []const u8, category: MemoryCategory, session_id: ?[]const u8) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.storeLocal(key, content, category, session_id);
    }

    fn implRecall(ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.ensureProjectionUpToDate();
        return self_.backend.recall(allocator, query, limit, session_id);
    }

    fn implGet(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.ensureProjectionUpToDate();
        return self_.backend.get(allocator, key);
    }

    fn implGetScoped(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8) anyerror!?MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.ensureProjectionUpToDate();
        return self_.backend.getScoped(allocator, key, session_id);
    }

    fn implList(ptr: *anyopaque, allocator: std.mem.Allocator, category: ?MemoryCategory, session_id: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.ensureProjectionUpToDate();
        return self_.backend.list(allocator, category, session_id);
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
        return self_.readEvents(allocator, after_sequence, limit);
    }

    fn implApplyEvent(ptr: *anyopaque, input: MemoryEventInput) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.applyRemoteEvent(input);
    }

    fn implLastEventSequence(ptr: *anyopaque) anyerror!u64 {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        var file = try self_.openJournalShared();
        defer file.close();
        try self_.refreshJournalLocked(&file);
        return self_.last_sequence;
    }

    fn implEventFeedInfo(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!MemoryEventFeedInfo {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        var file = try self_.openJournalShared();
        defer file.close();
        try self_.refreshJournalLocked(&file);
        return .{
            .instance_id = try allocator.dupe(u8, self_.instance_id),
            .last_sequence = self_.last_sequence,
            .supports_compaction = false,
        };
    }

    fn implCount(ptr: *anyopaque) anyerror!usize {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        var file = try self_.openJournalShared();
        defer file.close();
        try self_.refreshJournalLocked(&file);
        return self_.state_meta.count();
    }

    fn implHealthCheck(ptr: *anyopaque) bool {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        return self_.backend.healthCheck();
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
        .count = &implCount,
        .healthCheck = &implHealthCheck,
        .deinit = &implDeinit,
    };

    fn storeLocal(self: *Self, key: []const u8, content: []const u8, category: MemoryCategory, session_id: ?[]const u8) !void {
        var file = try self.openJournalExclusive();
        defer file.close();

        try self.refreshJournalLocked(&file);
        const input = try self.makeLocalInputLocked(.put, key, session_id, category, content);
        _ = try self.recordEventLocked(&file, input);
        try self.replayProjectionLocked(&file);
    }

    fn deleteLocalKey(self: *Self, key: []const u8) !bool {
        var file = try self.openJournalExclusive();
        defer file.close();

        try self.refreshJournalLocked(&file);
        const had_entry = self.hasAnyStateForKey(key);
        const input = try self.makeLocalInputLocked(.delete_all, key, null, null, null);
        _ = try self.recordEventLocked(&file, input);
        try self.replayProjectionLocked(&file);
        return had_entry;
    }

    fn deleteLocalScoped(self: *Self, key: []const u8, session_id: ?[]const u8) !bool {
        var file = try self.openJournalExclusive();
        defer file.close();

        try self.refreshJournalLocked(&file);
        const storage_key = try key_codec.encode(self.allocator, key, session_id);
        defer self.allocator.free(storage_key);
        const had_entry = self.state_meta.contains(storage_key);
        const input = try self.makeLocalInputLocked(.delete_scoped, key, session_id, null, null);
        _ = try self.recordEventLocked(&file, input);
        try self.replayProjectionLocked(&file);
        return had_entry;
    }

    fn applyRemoteEvent(self: *Self, input: MemoryEventInput) !void {
        var file = try self.openJournalExclusive();
        defer file.close();

        try self.refreshJournalLocked(&file);
        _ = try self.recordEventLocked(&file, input);
        try self.replayProjectionLocked(&file);
    }

    fn ensureProjectionUpToDate(self: *Self) !void {
        var file = try self.openJournalExclusive();
        defer file.close();
        try self.refreshJournalLocked(&file);
        try self.replayProjectionLocked(&file);
    }

    fn makeLocalInputLocked(
        self: *Self,
        operation: root.MemoryEventOp,
        key: []const u8,
        session_id: ?[]const u8,
        category: ?MemoryCategory,
        content: ?[]const u8,
    ) !MemoryEventInput {
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
            .content = content,
        };
    }

    fn recordEventLocked(self: *Self, file: *std.fs.File, input: MemoryEventInput) !bool {
        const frontier = self.origin_frontiers.get(input.origin_instance_id) orelse 0;
        if (input.origin_sequence <= frontier) return false;

        const effect = try self.computeMetadataEffect(input);
        const next_sequence = self.last_sequence + 1;
        const end_offset = try self.appendEventLineLocked(file, next_sequence, input, effect);
        try self.applyMetadataUpdate(next_sequence, input, effect);

        // The journal is canonical. The backend is a projection that may lag
        // behind temporarily if replay fails after the append.
        self.loaded_size_bytes = end_offset;
        return true;
    }

    fn replayProjectionLocked(self: *Self, file: *std.fs.File) !void {
        if (self.projection_offset_bytes >= self.loaded_size_bytes) return;

        try file.seekTo(self.projection_offset_bytes);

        const read_buf = try self.allocator.alloc(u8, MAX_EVENT_LINE_BYTES);
        defer self.allocator.free(read_buf);
        var reader = file.readerStreaming(read_buf);
        while (try reader.interface.takeDelimiter('\n')) |line_with_no_delim| {
            const line_end = try file.getPos();
            const line = std.mem.trim(u8, line_with_no_delim, " \t\r\n");
            if (line.len == 0) {
                self.projection_offset_bytes = line_end;
                continue;
            }

            var recorded = try parseRecordedEventLine(self.allocator, line);
            defer recorded.deinit(self.allocator);

            const input = memoryEventInput(recorded.event);
            const effect = recorded.effect orelse try self.computeMetadataEffect(input);
            try self.applyProjectionEffect(input, effect);
            self.projection_offset_bytes = line_end;
        }
    }

    fn refreshJournalLocked(self: *Self, file: *std.fs.File) !void {
        const end_pos = try file.getEndPos();
        if (end_pos < self.loaded_size_bytes) {
            self.clearJournalState();
            try self.loadJournalFromOffsetLocked(file, 0);
            return;
        }

        if (end_pos == self.loaded_size_bytes) return;
        try self.loadJournalFromOffsetLocked(file, self.loaded_size_bytes);
    }

    fn loadJournalFromOffsetLocked(self: *Self, file: *std.fs.File, start_offset: u64) !void {
        try file.seekTo(start_offset);

        const read_buf = try self.allocator.alloc(u8, MAX_EVENT_LINE_BYTES);
        defer self.allocator.free(read_buf);
        var reader = file.readerStreaming(read_buf);
        while (try reader.interface.takeDelimiter('\n')) |line_with_no_delim| {
            const line_end = try file.getPos();
            const line = std.mem.trim(u8, line_with_no_delim, " \t\r\n");
            if (line.len == 0) {
                self.loaded_size_bytes = line_end;
                continue;
            }

            var recorded = try parseRecordedEventLine(self.allocator, line);
            defer recorded.deinit(self.allocator);

            const input = memoryEventInput(recorded.event);
            const effect = recorded.effect orelse try self.computeMetadataEffect(input);
            try self.applyMetadataUpdate(recorded.event.sequence, input, effect);
            self.loaded_size_bytes = line_end;
        }
    }

    fn computeMetadataEffect(self: *Self, input: MemoryEventInput) !Effect {
        return switch (input.operation) {
            .put => blk: {
                if (input.category == null or input.content == null) return error.InvalidEvent;
                const storage_key = try key_codec.encode(self.allocator, input.key, input.session_id);
                defer self.allocator.free(storage_key);

                if (self.key_tombstones.get(input.key)) |meta| {
                    if (compareMeta(meta, input) <= 0) break :blk .none;
                }
                if (self.scoped_tombstones.get(storage_key)) |meta| {
                    if (compareMeta(meta, input) <= 0) break :blk .none;
                }
                if (self.state_meta.get(storage_key)) |meta| {
                    if (compareMeta(meta, input) <= 0) break :blk .none;
                }
                break :blk .put;
            },
            .delete_scoped => blk: {
                const storage_key = try key_codec.encode(self.allocator, input.key, input.session_id);
                defer self.allocator.free(storage_key);

                if (self.key_tombstones.get(input.key)) |meta| {
                    if (compareMeta(meta, input) <= 0) break :blk .none;
                }
                if (self.scoped_tombstones.get(storage_key)) |meta| {
                    if (compareMeta(meta, input) <= 0) break :blk .none;
                }
                break :blk .delete_scoped;
            },
            .delete_all => blk: {
                if (self.key_tombstones.get(input.key)) |meta| {
                    if (compareMeta(meta, input) <= 0) break :blk .none;
                }
                break :blk .delete_all;
            },
        };
    }

    fn applyMetadataUpdate(self: *Self, sequence: u64, input: MemoryEventInput, effect: Effect) !void {
        self.last_sequence = @max(self.last_sequence, sequence);
        self.last_timestamp_ms = @max(self.last_timestamp_ms, input.timestamp_ms);
        try self.rememberOriginFrontier(input.origin_instance_id, input.origin_sequence);

        switch (effect) {
            .none => {},
            .put => {
                const storage_key = try key_codec.encode(self.allocator, input.key, input.session_id);
                defer self.allocator.free(storage_key);
                try self.rememberStateMeta(storage_key, input);
            },
            .delete_scoped => {
                const storage_key = try key_codec.encode(self.allocator, input.key, input.session_id);
                defer self.allocator.free(storage_key);
                try self.removeStateMeta(storage_key);
                try self.rememberScopedTombstone(storage_key, input);
            },
            .delete_all => {
                try self.removeStateEntriesForKey(input.key);
                try self.rememberKeyTombstone(input.key, input);
            },
        }
    }

    fn applyProjectionEffect(self: *Self, input: MemoryEventInput, effect: Effect) !void {
        switch (effect) {
            .none => {},
            .put => {
                try self.backend.store(input.key, input.content.?, input.category.?, input.session_id);
            },
            .delete_scoped => {
                _ = try self.backend.forgetScoped(self.allocator, input.key, input.session_id);
            },
            .delete_all => {
                _ = try self.backend.forget(input.key);
            },
        }
    }

    fn rememberOriginFrontier(self: *Self, origin_instance_id: []const u8, origin_sequence: u64) !void {
        if (self.origin_frontiers.getPtr(origin_instance_id)) |existing| {
            existing.* = @max(existing.*, origin_sequence);
            return;
        }
        try self.origin_frontiers.put(self.allocator, try self.allocator.dupe(u8, origin_instance_id), origin_sequence);
    }

    fn rememberStateMeta(self: *Self, storage_key: []const u8, input: MemoryEventInput) !void {
        const meta = try self.dupEventMeta(input);
        errdefer self.freeEventMeta(meta);
        if (self.state_meta.getPtr(storage_key)) |existing| {
            self.freeEventMeta(existing.*);
            existing.* = meta;
            return;
        }
        try self.state_meta.put(self.allocator, try self.allocator.dupe(u8, storage_key), meta);
    }

    fn removeStateMeta(self: *Self, storage_key: []const u8) !void {
        if (self.state_meta.fetchRemove(storage_key)) |removed| {
            self.allocator.free(removed.key);
            self.freeEventMeta(removed.value);
        }
    }

    fn rememberScopedTombstone(self: *Self, storage_key: []const u8, input: MemoryEventInput) !void {
        const meta = try self.dupEventMeta(input);
        errdefer self.freeEventMeta(meta);
        if (self.scoped_tombstones.getPtr(storage_key)) |existing| {
            if (compareMeta(existing.*, input) >= 0) {
                self.freeEventMeta(meta);
                return;
            }
            self.freeEventMeta(existing.*);
            existing.* = meta;
            return;
        }
        try self.scoped_tombstones.put(self.allocator, try self.allocator.dupe(u8, storage_key), meta);
    }

    fn rememberKeyTombstone(self: *Self, key: []const u8, input: MemoryEventInput) !void {
        const meta = try self.dupEventMeta(input);
        errdefer self.freeEventMeta(meta);
        if (self.key_tombstones.getPtr(key)) |existing| {
            if (compareMeta(existing.*, input) >= 0) {
                self.freeEventMeta(meta);
                return;
            }
            self.freeEventMeta(existing.*);
            existing.* = meta;
            return;
        }
        try self.key_tombstones.put(self.allocator, try self.allocator.dupe(u8, key), meta);
    }

    fn dupEventMeta(self: *Self, input: MemoryEventInput) !EventMeta {
        return .{
            .timestamp_ms = input.timestamp_ms,
            .origin_instance_id = try self.allocator.dupe(u8, input.origin_instance_id),
            .origin_sequence = input.origin_sequence,
        };
    }

    fn freeEventMeta(self: *Self, meta: EventMeta) void {
        self.allocator.free(meta.origin_instance_id);
    }

    fn hasAnyStateForKey(self: *Self, key: []const u8) bool {
        var it = self.state_meta.iterator();
        while (it.next()) |kv| {
            const decoded = key_codec.decode(kv.key_ptr.*);
            if (std.mem.eql(u8, decoded.logical_key, key)) return true;
        }
        return false;
    }

    fn removeStateEntriesForKey(self: *Self, key: []const u8) !void {
        var to_remove: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (to_remove.items) |owned| self.allocator.free(owned);
            to_remove.deinit(self.allocator);
        }

        var it = self.state_meta.iterator();
        while (it.next()) |kv| {
            const decoded = key_codec.decode(kv.key_ptr.*);
            if (std.mem.eql(u8, decoded.logical_key, key)) {
                try to_remove.append(self.allocator, try self.allocator.dupe(u8, kv.key_ptr.*));
            }
        }

        for (to_remove.items) |storage_key| {
            try self.removeStateMeta(storage_key);
        }
    }

    fn appendEventLineLocked(self: *Self, file: *std.fs.File, sequence: u64, input: MemoryEventInput, effect: Effect) !u64 {
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(self.allocator);

        try payload.append(self.allocator, '{');
        try json_util.appendJsonInt(&payload, self.allocator, "schema_version", 1);
        try payload.append(self.allocator, ',');
        try json_util.appendJsonKey(&payload, self.allocator, "sequence");
        try payload.writer(self.allocator).print("{d}", .{sequence});
        try payload.append(self.allocator, ',');
        try json_util.appendJsonKeyValue(&payload, self.allocator, "origin_instance_id", input.origin_instance_id);
        try payload.append(self.allocator, ',');
        try json_util.appendJsonKey(&payload, self.allocator, "origin_sequence");
        try payload.writer(self.allocator).print("{d}", .{input.origin_sequence});
        try payload.append(self.allocator, ',');
        try json_util.appendJsonKey(&payload, self.allocator, "timestamp_ms");
        try payload.writer(self.allocator).print("{d}", .{input.timestamp_ms});
        try payload.append(self.allocator, ',');
        try json_util.appendJsonKeyValue(&payload, self.allocator, "operation", input.operation.toString());
        try payload.append(self.allocator, ',');
        try json_util.appendJsonKeyValue(&payload, self.allocator, "effect", effect.toString());
        try payload.append(self.allocator, ',');
        try json_util.appendJsonKeyValue(&payload, self.allocator, "key", input.key);
        try payload.append(self.allocator, ',');
        try json_util.appendJsonKey(&payload, self.allocator, "session_id");
        if (input.session_id) |sid| {
            try json_util.appendJsonString(&payload, self.allocator, sid);
        } else {
            try payload.appendSlice(self.allocator, "null");
        }
        try payload.append(self.allocator, ',');
        try json_util.appendJsonKey(&payload, self.allocator, "category");
        if (input.category) |category| {
            try json_util.appendJsonString(&payload, self.allocator, category.toString());
        } else {
            try payload.appendSlice(self.allocator, "null");
        }
        try payload.append(self.allocator, ',');
        try json_util.appendJsonKey(&payload, self.allocator, "content");
        if (input.content) |content| {
            try json_util.appendJsonString(&payload, self.allocator, content);
        } else {
            try payload.appendSlice(self.allocator, "null");
        }
        try payload.appendSlice(self.allocator, "}\n");

        try file.seekFromEnd(0);
        try file.writeAll(payload.items);
        try file.sync();
        return try file.getPos();
    }

    fn readEvents(self: *Self, allocator: std.mem.Allocator, after_sequence: u64, limit: usize) ![]MemoryEvent {
        if (limit == 0) return allocator.alloc(MemoryEvent, 0);

        var file = try self.openJournalShared();
        defer file.close();

        try file.seekTo(0);

        const read_buf = try self.allocator.alloc(u8, MAX_EVENT_LINE_BYTES);
        defer self.allocator.free(read_buf);
        var reader = file.readerStreaming(read_buf);
        var events: std.ArrayListUnmanaged(MemoryEvent) = .empty;
        errdefer {
            for (events.items) |*event| event.deinit(allocator);
            events.deinit(allocator);
        }

        while (try reader.interface.takeDelimiter('\n')) |line_with_no_delim| {
            const line = std.mem.trim(u8, line_with_no_delim, " \t\r\n");
            if (line.len == 0) continue;

            var recorded = try parseRecordedEventLine(allocator, line);
            if (recorded.event.sequence <= after_sequence) {
                recorded.deinit(allocator);
                continue;
            }

            try events.append(allocator, recorded.event);
            if (events.items.len >= limit) break;
        }

        return events.toOwnedSlice(allocator);
    }

    fn bootstrapFromBackendLocked(self: *Self, file: *std.fs.File) !void {
        const entries = if (std.mem.eql(u8, self.backend.name(), "markdown"))
            try blk: {
                const markdown_backend: *root.MarkdownMemory = @ptrCast(@alignCast(self.backend.ptr));
                break :blk markdown_backend.exportAllEntries(self.allocator);
            }
        else
            try self.backend.list(self.allocator, null, null);
        defer root.freeEntries(self.allocator, entries);

        if (entries.len == 0) return;

        var bootstrap_entries = try self.allocator.alloc(BootstrapEntry, entries.len);
        defer {
            for (bootstrap_entries) |entry| {
                self.allocator.free(entry.key);
                self.allocator.free(entry.content);
                if (entry.session_id) |sid| self.allocator.free(sid);
                switch (entry.category) {
                    .custom => |name| self.allocator.free(name),
                    else => {},
                }
            }
            self.allocator.free(bootstrap_entries);
        }

        for (entries, 0..) |entry, idx| {
            bootstrap_entries[idx] = .{
                .key = try self.allocator.dupe(u8, entry.key),
                .content = try self.allocator.dupe(u8, entry.content),
                .category = try dupCategory(self.allocator, entry.category),
                .session_id = if (entry.session_id) |sid| try self.allocator.dupe(u8, sid) else null,
            };
        }

        std.mem.sort(BootstrapEntry, bootstrap_entries, {}, struct {
            fn lessThan(_: void, a: BootstrapEntry, b: BootstrapEntry) bool {
                const key_order = std.mem.order(u8, a.key, b.key);
                if (key_order == .lt) return true;
                if (key_order == .gt) return false;
                if (a.session_id == null and b.session_id != null) return true;
                if (a.session_id != null and b.session_id == null) return false;
                if (a.session_id) |sid_a| {
                    return std.mem.order(u8, sid_a, b.session_id.?) == .lt;
                }
                return false;
            }
        }.lessThan);

        for (bootstrap_entries, 0..) |entry, idx| {
            const sequence: u64 = @intCast(idx + 1);
            const input = MemoryEventInput{
                .origin_instance_id = self.instance_id,
                .origin_sequence = sequence,
                .timestamp_ms = @intCast(sequence),
                .operation = .put,
                .key = entry.key,
                .session_id = entry.session_id,
                .category = entry.category,
                .content = entry.content,
            };
            const end_offset = try self.appendEventLineLocked(file, sequence, input, .put);
            try self.applyMetadataUpdate(sequence, input, .put);
            self.loaded_size_bytes = end_offset;
            self.projection_offset_bytes = end_offset;
        }
    }

    fn openJournalExclusive(self: *Self) !std.fs.File {
        return std.fs.createFileAbsolute(self.journal_path, .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
        });
    }

    fn openJournalShared(self: *Self) !std.fs.File {
        return std.fs.openFileAbsolute(self.journal_path, .{
            .mode = .read_only,
            .lock = .shared,
        }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                var created = try std.fs.createFileAbsolute(self.journal_path, .{
                    .read = true,
                    .truncate = false,
                });
                created.close();
                break :blk try std.fs.openFileAbsolute(self.journal_path, .{
                    .mode = .read_only,
                    .lock = .shared,
                });
            },
            else => err,
        };
    }
};

fn compareMeta(meta: EventFeedOverlay.EventMeta, input: MemoryEventInput) i8 {
    if (input.timestamp_ms < meta.timestamp_ms) return -1;
    if (input.timestamp_ms > meta.timestamp_ms) return 1;

    const order = std.mem.order(u8, input.origin_instance_id, meta.origin_instance_id);
    if (order == .lt) return -1;
    if (order == .gt) return 1;

    if (input.origin_sequence < meta.origin_sequence) return -1;
    if (input.origin_sequence > meta.origin_sequence) return 1;
    return 0;
}

fn ensureJournalParent(journal_path: []const u8) !void {
    const parent = std.fs.path.dirname(journal_path) orelse return;
    std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => try fs_compat.makePath(parent),
    };
}

fn buildJournalPath(allocator: std.mem.Allocator, journal_root_dir: []const u8, journal_identity: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(journal_identity, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const filename = try std.fmt.allocPrint(allocator, ".nullclaw-feed.{s}.jsonl", .{hex[0..]});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ journal_root_dir, filename });
}

fn memoryEventInput(event: MemoryEvent) MemoryEventInput {
    return .{
        .origin_instance_id = event.origin_instance_id,
        .origin_sequence = event.origin_sequence,
        .timestamp_ms = event.timestamp_ms,
        .operation = event.operation,
        .key = event.key,
        .session_id = event.session_id,
        .category = event.category,
        .content = event.content,
    };
}

fn parseRecordedEventLine(allocator: std.mem.Allocator, line: []const u8) !EventFeedOverlay.RecordedEvent {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    const val = parsed.value;
    const sequence = jsonUnsignedField(val, "sequence") orelse return error.InvalidEvent;
    const origin_instance_id = jsonStringField(val, "origin_instance_id") orelse return error.InvalidEvent;
    const origin_sequence = jsonUnsignedField(val, "origin_sequence") orelse return error.InvalidEvent;
    const timestamp_ms = jsonIntegerField(val, "timestamp_ms") orelse return error.InvalidEvent;
    const operation_str = jsonStringField(val, "operation") orelse return error.InvalidEvent;
    const key = jsonStringField(val, "key") orelse return error.InvalidEvent;

    return .{
        .event = .{
            .schema_version = @intCast(jsonUnsignedField(val, "schema_version") orelse 1),
            .sequence = sequence,
            .origin_instance_id = try allocator.dupe(u8, origin_instance_id),
            .origin_sequence = origin_sequence,
            .timestamp_ms = timestamp_ms,
            .operation = root.MemoryEventOp.fromString(operation_str) orelse return error.InvalidEvent,
            .key = try allocator.dupe(u8, key),
            .session_id = if (jsonNullableStringField(val, "session_id")) |sid| try allocator.dupe(u8, sid) else null,
            .category = if (jsonNullableStringField(val, "category")) |cat| root.MemoryCategory.fromString(cat) else null,
            .content = if (jsonNullableStringField(val, "content")) |content| try allocator.dupe(u8, content) else null,
        },
        .effect = blk: {
            const effect_str = jsonStringField(val, "effect") orelse break :blk null;
            break :blk EventFeedOverlay.Effect.fromString(effect_str) orelse return error.InvalidEvent;
        },
    };
}

fn jsonStringField(val: std.json.Value, key: []const u8) ?[]const u8 {
    if (val != .object) return null;
    const field = val.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

fn jsonNullableStringField(val: std.json.Value, key: []const u8) ?[]const u8 {
    if (val != .object) return null;
    const field = val.object.get(key) orelse return null;
    if (field == .null) return null;
    return if (field == .string) field.string else null;
}

fn jsonIntegerField(val: std.json.Value, key: []const u8) ?i64 {
    if (val != .object) return null;
    const field = val.object.get(key) orelse return null;
    return switch (field) {
        .integer => field.integer,
        else => null,
    };
}

fn jsonUnsignedField(val: std.json.Value, key: []const u8) ?u64 {
    const value = jsonIntegerField(val, key) orelse return null;
    if (value < 0) return null;
    return @intCast(value);
}

fn dupCategory(allocator: std.mem.Allocator, cat: MemoryCategory) !MemoryCategory {
    return switch (cat) {
        .custom => |name| .{ .custom = try allocator.dupe(u8, name) },
        else => cat,
    };
}

const FailingProjectionBackend = struct {
    allocator: std.mem.Allocator,
    state: std.StringHashMapUnmanaged([]u8) = .{},
    fail_writes: bool = true,

    fn init(allocator: std.mem.Allocator) FailingProjectionBackend {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *FailingProjectionBackend) void {
        var it = self.state.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.*);
        }
        self.state.deinit(self.allocator);
    }

    fn memory(self: *FailingProjectionBackend) Memory {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn implName(_: *anyopaque) []const u8 {
        return "failing-projection";
    }

    fn implStore(ptr: *anyopaque, key: []const u8, content: []const u8, _: MemoryCategory, _: ?[]const u8) anyerror!void {
        const self_: *FailingProjectionBackend = @ptrCast(@alignCast(ptr));
        if (self_.fail_writes) return error.BackendUnavailable;
        const owned_key = try self_.allocator.dupe(u8, key);
        errdefer self_.allocator.free(owned_key);
        const owned_content = try self_.allocator.dupe(u8, content);
        errdefer self_.allocator.free(owned_content);
        if (try self_.state.fetchPut(self_.allocator, owned_key, owned_content)) |existing| {
            self_.allocator.free(existing.key);
            self_.allocator.free(existing.value);
        }
    }

    fn implRecall(ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8, limit: usize, _: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *FailingProjectionBackend = @ptrCast(@alignCast(ptr));
        var out: std.ArrayListUnmanaged(MemoryEntry) = .empty;
        errdefer {
            for (out.items) |*entry| entry.deinit(allocator);
            out.deinit(allocator);
        }

        var it = self_.state.iterator();
        while (it.next()) |kv| {
            if (!std.mem.containsAtLeast(u8, kv.value_ptr.*, 1, query)) continue;
            try out.append(allocator, .{
                .id = try allocator.dupe(u8, kv.key_ptr.*),
                .key = try allocator.dupe(u8, kv.key_ptr.*),
                .content = try allocator.dupe(u8, kv.value_ptr.*),
                .category = .core,
                .timestamp = try allocator.dupe(u8, "0"),
                .session_id = null,
            });
            if (out.items.len >= limit) break;
        }

        return out.toOwnedSlice(allocator);
    }

    fn implGet(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?MemoryEntry {
        const self_: *FailingProjectionBackend = @ptrCast(@alignCast(ptr));
        const value = self_.state.get(key) orelse return null;
        return .{
            .id = try allocator.dupe(u8, key),
            .key = try allocator.dupe(u8, key),
            .content = try allocator.dupe(u8, value),
            .category = .core,
            .timestamp = try allocator.dupe(u8, "0"),
            .session_id = null,
        };
    }

    fn implGetScoped(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, _: ?[]const u8) anyerror!?MemoryEntry {
        return implGet(ptr, allocator, key);
    }

    fn implList(ptr: *anyopaque, allocator: std.mem.Allocator, _: ?MemoryCategory, _: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *FailingProjectionBackend = @ptrCast(@alignCast(ptr));
        var out: std.ArrayListUnmanaged(MemoryEntry) = .empty;
        errdefer {
            for (out.items) |*entry| entry.deinit(allocator);
            out.deinit(allocator);
        }

        var it = self_.state.iterator();
        while (it.next()) |kv| {
            try out.append(allocator, .{
                .id = try allocator.dupe(u8, kv.key_ptr.*),
                .key = try allocator.dupe(u8, kv.key_ptr.*),
                .content = try allocator.dupe(u8, kv.value_ptr.*),
                .category = .core,
                .timestamp = try allocator.dupe(u8, "0"),
                .session_id = null,
            });
        }

        return out.toOwnedSlice(allocator);
    }

    fn implForget(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self_: *FailingProjectionBackend = @ptrCast(@alignCast(ptr));
        if (self_.fail_writes) return error.BackendUnavailable;
        if (self_.state.fetchRemove(key)) |removed| {
            self_.allocator.free(removed.key);
            self_.allocator.free(removed.value);
            return true;
        }
        return false;
    }

    fn implForgetScoped(ptr: *anyopaque, key: []const u8, _: ?[]const u8) anyerror!bool {
        return implForget(ptr, key);
    }

    fn implCount(ptr: *anyopaque) anyerror!usize {
        const self_: *FailingProjectionBackend = @ptrCast(@alignCast(ptr));
        return self_.state.count();
    }

    fn implHealthCheck(_: *anyopaque) bool {
        return true;
    }

    fn implDeinit(ptr: *anyopaque) void {
        const self_: *FailingProjectionBackend = @ptrCast(@alignCast(ptr));
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
        .count = &implCount,
        .healthCheck = &implHealthCheck,
        .deinit = &implDeinit,
    };
};

test "feed overlay bootstraps markdown backend state into events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    var backend = try root.MarkdownMemory.init(std.testing.allocator, workspace);
    const memory = backend.memory();
    try memory.store("preferences.theme", "dark", .core, null);
    try memory.store("preferences.locale", "en", .core, "sess-a");

    var overlay = try EventFeedOverlay.init(std.testing.allocator, memory, workspace, "markdown-bootstrap", "agent-a");
    defer overlay.deinit();

    const events = try overlay.memory().listEvents(std.testing.allocator, 0, 10);
    defer root.freeEvents(std.testing.allocator, events);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expect(std.mem.eql(u8, events[0].key, "preferences.locale") or std.mem.eql(u8, events[1].key, "preferences.locale"));
    if (std.mem.eql(u8, events[0].key, "preferences.locale")) {
        try std.testing.expectEqualStrings("sess-a", events[0].session_id.?);
    } else {
        try std.testing.expectEqualStrings("sess-a", events[1].session_id.?);
    }
}

test "feed overlay converges markdown replicas" {
    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    const ws_a = try tmp_a.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(ws_a);

    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();
    const ws_b = try tmp_b.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(ws_b);

    var source_backend = try root.MarkdownMemory.init(std.testing.allocator, ws_a);
    var replica_backend = try root.MarkdownMemory.init(std.testing.allocator, ws_b);

    var source = try EventFeedOverlay.init(std.testing.allocator, source_backend.memory(), ws_a, "markdown-source", "agent-a");
    defer source.deinit();
    var replica = try EventFeedOverlay.init(std.testing.allocator, replica_backend.memory(), ws_b, "markdown-replica", "agent-b");
    defer replica.deinit();

    const source_mem = source.memory();
    const replica_mem = replica.memory();

    try source_mem.store("preferences.tone", "formal", .core, null);
    try source_mem.store("preferences.locale", "ru", .core, "sess-a");
    try std.testing.expect(try source_mem.forgetScoped(std.testing.allocator, "preferences.locale", "sess-a"));

    const events = try source_mem.listEvents(std.testing.allocator, 0, 16);
    defer root.freeEvents(std.testing.allocator, events);

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

    const tone = (try replica_mem.getScoped(std.testing.allocator, "preferences.tone", null)).?;
    defer tone.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("formal", tone.content);

    const locale = try replica_mem.getScoped(std.testing.allocator, "preferences.locale", "sess-a");
    defer if (locale) |entry| entry.deinit(std.testing.allocator);
    try std.testing.expect(locale == null);
}

test "feed overlay journals before backend projection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const workspace = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(workspace);

    var backend = FailingProjectionBackend.init(std.testing.allocator);
    var overlay = try EventFeedOverlay.init(std.testing.allocator, backend.memory(), workspace, "failing-backend", "agent-a");
    defer overlay.deinit();

    const mem = overlay.memory();
    try std.testing.expectError(error.BackendUnavailable, mem.store("preferences.theme", "dark", .core, null));

    const events = try mem.listEvents(std.testing.allocator, 0, 8);
    defer root.freeEvents(std.testing.allocator, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("preferences.theme", events[0].key);

    backend.fail_writes = false;
    const entry = (try mem.getScoped(std.testing.allocator, "preferences.theme", null)).?;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dark", entry.content);
}
