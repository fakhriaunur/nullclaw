//! Redis-backed persistent memory via RESP (REdis Serialization Protocol) over TCP.
//!
//! No C dependency — implements a minimal RESP v2 client directly.
//! Designed for distributed memory sharing across multiple nullclaw instances.

const std = @import("std");
const json_util = @import("../../json_util.zig");
const root = @import("../root.zig");
const key_codec = @import("../vector/key_codec.zig");
const Memory = root.Memory;
const MemoryEvent = root.MemoryEvent;
const MemoryEventFeedInfo = root.MemoryEventFeedInfo;
const MemoryEventInput = root.MemoryEventInput;
const MemoryValueKind = root.MemoryValueKind;
const MemoryCategory = root.MemoryCategory;
const MemoryEntry = root.MemoryEntry;
const log = std.log.scoped(.redis_memory);

// ── RESP types ──────────────────────────────────────────────────────

pub const RespValue = union(enum) {
    simple_string: []const u8,
    err: []const u8,
    integer: i64,
    bulk_string: ?[]const u8,
    array: ?[]RespValue,

    pub fn deinit(self: *RespValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .simple_string => |s| allocator.free(s),
            .err => |s| allocator.free(s),
            .bulk_string => |maybe_s| if (maybe_s) |s| allocator.free(s),
            .array => |maybe_arr| if (maybe_arr) |arr| {
                for (arr) |*item| item.deinit(allocator);
                allocator.free(arr);
            },
            .integer => {},
        }
    }

    /// Return the value as a string slice (simple_string or bulk_string).
    pub fn asString(self: RespValue) ?[]const u8 {
        return switch (self) {
            .simple_string => |s| s,
            .bulk_string => |maybe_s| maybe_s,
            else => null,
        };
    }
};

// ── RESP protocol helpers ───────────────────────────────────────────

/// Format a Redis command as a RESP array of bulk strings.
pub fn formatCommand(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // *N\r\n
    const header = try std.fmt.allocPrint(allocator, "*{d}\r\n", .{args.len});
    defer allocator.free(header);
    try buf.appendSlice(allocator, header);

    for (args) |arg| {
        // $len\r\n{arg}\r\n
        const prefix = try std.fmt.allocPrint(allocator, "${d}\r\n", .{arg.len});
        defer allocator.free(prefix);
        try buf.appendSlice(allocator, prefix);
        try buf.appendSlice(allocator, arg);
        try buf.appendSlice(allocator, "\r\n");
    }

    return buf.toOwnedSlice(allocator);
}

/// Parse a single RESP value from the given data buffer.
/// Returns the parsed value and the number of bytes consumed.
pub fn parseResp(allocator: std.mem.Allocator, data: []const u8) !struct { value: RespValue, consumed: usize } {
    if (data.len == 0) return error.IncompleteData;

    const type_byte = data[0];
    const rest = data[1..];

    switch (type_byte) {
        '+' => {
            // Simple string: +OK\r\n
            const end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.IncompleteData;
            const s = try allocator.dupe(u8, rest[0..end]);
            return .{ .value = .{ .simple_string = s }, .consumed = 1 + end + 2 };
        },
        '-' => {
            // Error: -ERR message\r\n
            const end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.IncompleteData;
            const s = try allocator.dupe(u8, rest[0..end]);
            return .{ .value = .{ .err = s }, .consumed = 1 + end + 2 };
        },
        ':' => {
            // Integer: :42\r\n
            const end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.IncompleteData;
            const n = try std.fmt.parseInt(i64, rest[0..end], 10);
            return .{ .value = .{ .integer = n }, .consumed = 1 + end + 2 };
        },
        '$' => {
            // Bulk string: $len\r\n{data}\r\n  or  $-1\r\n (null)
            const end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.IncompleteData;
            const len = try std.fmt.parseInt(i64, rest[0..end], 10);
            if (len < 0) {
                return .{ .value = .{ .bulk_string = null }, .consumed = 1 + end + 2 };
            }
            const ulen: usize = @intCast(len);
            const data_start = end + 2;
            if (rest.len < data_start + ulen + 2) return error.IncompleteData;
            const s = try allocator.dupe(u8, rest[data_start .. data_start + ulen]);
            return .{ .value = .{ .bulk_string = s }, .consumed = 1 + data_start + ulen + 2 };
        },
        '*' => {
            // Array: *N\r\n...  or  *-1\r\n (null)
            const end = std.mem.indexOf(u8, rest, "\r\n") orelse return error.IncompleteData;
            const count = try std.fmt.parseInt(i64, rest[0..end], 10);
            if (count < 0) {
                return .{ .value = .{ .array = null }, .consumed = 1 + end + 2 };
            }
            const ucount: usize = @intCast(count);
            var items = try allocator.alloc(RespValue, ucount);
            var total_consumed: usize = 1 + end + 2;
            var i: usize = 0;
            errdefer {
                for (items[0..i]) |*item| item.deinit(allocator);
                allocator.free(items);
            }
            while (i < ucount) : (i += 1) {
                const result = try parseResp(allocator, data[total_consumed..]);
                items[i] = result.value;
                total_consumed += result.consumed;
            }
            return .{ .value = .{ .array = items }, .consumed = total_consumed };
        },
        else => return error.UnknownRespType,
    }
}

// ── Redis config ────────────────────────────────────────────────────

pub const RedisConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 6379,
    password: ?[]const u8 = null,
    db_index: u8 = 0,
    key_prefix: []const u8 = "nullclaw",
    ttl_seconds: ?u32 = null,
    instance_id: []const u8 = "default",
};

fn normalizeInstanceId(instance_id: []const u8) []const u8 {
    return if (instance_id.len > 0) instance_id else "default";
}

// ── RedisMemory ─────────────────────────────────────────────────────

pub const RedisMemory = struct {
    allocator: std.mem.Allocator,
    stream: ?std.net.Stream = null,
    host: []const u8,
    port: u16,
    password: ?[]const u8,
    db_index: u8,
    key_prefix: []const u8,
    ttl_seconds: ?u32,
    instance_id: []const u8 = "default",
    owns_self: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: RedisConfig) !Self {
        var self_ = Self{
            .allocator = allocator,
            .host = config.host,
            .port = config.port,
            .password = config.password,
            .db_index = config.db_index,
            .key_prefix = config.key_prefix,
            .ttl_seconds = config.ttl_seconds,
            .instance_id = normalizeInstanceId(config.instance_id),
        };

        try self_.connect();
        try self_.backfillFeedFromExistingState();
        return self_;
    }

    pub fn deinit(self: *Self) void {
        if (self.stream) |stream| {
            stream.close();
            self.stream = null;
        }
        if (self.owns_self) {
            self.allocator.destroy(self);
        }
    }

    fn connect(self: *Self) anyerror!void {
        const addr = try std.net.Address.resolveIp(self.host, self.port);
        const stream = try std.net.tcpConnectToAddress(addr);
        self.stream = stream;

        // AUTH if password set (stream is already connected, ensureConnected is a no-op)
        if (self.password) |pwd| {
            var resp = try self.sendCommandAlloc(self.allocator, &.{ "AUTH", pwd });
            defer resp.deinit(self.allocator);
            switch (resp) {
                .err => |msg| {
                    log.err("AUTH failed: {s}", .{msg});
                    return error.AuthFailed;
                },
                else => {},
            }
        }

        // SELECT database
        if (self.db_index != 0) {
            var db_buf: [4]u8 = undefined;
            const db_str = std.fmt.bufPrint(&db_buf, "{d}", .{self.db_index}) catch unreachable;
            var resp = try self.sendCommandAlloc(self.allocator, &.{ "SELECT", db_str });
            defer resp.deinit(self.allocator);
            switch (resp) {
                .err => |msg| {
                    log.err("SELECT failed: {s}", .{msg});
                    return error.SelectFailed;
                },
                else => {},
            }
        }
    }

    fn ensureConnected(self: *Self) !void {
        if (self.stream != null) return;
        try self.connect();
    }

    // ── Low-level RESP I/O ─────────────────────────────────────────

    fn sendCommand(self: *Self, args: []const []const u8) !RespValue {
        return self.sendCommandAlloc(self.allocator, args);
    }

    fn sendCommandAlloc(self: *Self, allocator: std.mem.Allocator, args: []const []const u8) !RespValue {
        try self.ensureConnected();
        const stream = self.stream orelse return error.NotConnected;

        const cmd = try formatCommand(self.allocator, args);
        defer self.allocator.free(cmd);

        stream.writeAll(cmd) catch |err| {
            self.stream = null;
            return err;
        };

        return self.readResponse(allocator);
    }

    fn readResponse(self: *Self, allocator: std.mem.Allocator) !RespValue {
        const stream = self.stream orelse return error.NotConnected;
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(self.allocator);

        while (true) {
            var buf: [4096]u8 = undefined;
            const n = stream.read(&buf) catch |err| {
                self.stream = null;
                return err;
            };
            if (n == 0) {
                self.stream = null;
                return error.ConnectionClosed;
            }
            try data.appendSlice(self.allocator, buf[0..n]);

            const result = parseResp(allocator, data.items) catch |err| switch (err) {
                error.IncompleteData => continue,
                else => return err,
            };
            return result.value;
        }
    }

    // ── Key helpers ────────────────────────────────────────────────

    fn prefixedKey(self: *Self, comptime suffix: []const u8, key: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}:{s}:{s}:{s}", .{ self.key_prefix, self.instance_id, suffix, key });
    }

    fn prefixedSimple(self: *Self, comptime suffix: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}:{s}:{s}", .{ self.key_prefix, self.instance_id, suffix });
    }

    fn localInstanceId(self: *Self) []const u8 {
        return normalizeInstanceId(self.instance_id);
    }

    fn feedEventsKey(self: *Self) ![]u8 {
        return self.prefixedSimple("feed:events");
    }

    fn feedMetaKey(self: *Self) ![]u8 {
        return self.prefixedSimple("feed:meta");
    }

    fn feedFrontiersKey(self: *Self) ![]u8 {
        return self.prefixedSimple("feed:frontiers");
    }

    fn tombScopedIndexKey(self: *Self) ![]u8 {
        return self.prefixedSimple("feed:tombstones:scoped");
    }

    fn tombKeyIndexKey(self: *Self) ![]u8 {
        return self.prefixedSimple("feed:tombstones:key");
    }

    fn tombScopedKey(self: *Self, storage_key: []const u8) ![]u8 {
        return self.prefixedKey("feed:tombstone:scoped", storage_key);
    }

    fn tombKeyKey(self: *Self, key: []const u8) ![]u8 {
        return self.prefixedKey("feed:tombstone:key", key);
    }

    fn sessionKeyFor(session_id: ?[]const u8) []const u8 {
        return if (session_id) |sid| sid else "__global__";
    }

    fn compareInputToMetadata(input: MemoryEventInput, timestamp_ms: i64, origin_instance_id: []const u8, origin_sequence: u64) i8 {
        if (input.timestamp_ms < timestamp_ms) return -1;
        if (input.timestamp_ms > timestamp_ms) return 1;
        const order = std.mem.order(u8, input.origin_instance_id, origin_instance_id);
        if (order == .lt) return -1;
        if (order == .gt) return 1;
        if (input.origin_sequence < origin_sequence) return -1;
        if (input.origin_sequence > origin_sequence) return 1;
        return 0;
    }

    // ── Timestamp / ID helpers ─────────────────────────────────────

    fn getNowTimestamp(allocator: std.mem.Allocator) ![]u8 {
        const ts = std.time.timestamp();
        return std.fmt.allocPrint(allocator, "{d}", .{ts});
    }

    fn generateId(allocator: std.mem.Allocator) ![]u8 {
        const ts = std.time.nanoTimestamp();
        var rand_buf: [16]u8 = undefined;
        std.crypto.random.bytes(&rand_buf);
        const hi = std.mem.readInt(u64, rand_buf[0..8], .little);
        const lo = std.mem.readInt(u64, rand_buf[8..16], .little);
        return std.fmt.allocPrint(allocator, "{d}-{x}-{x}", .{ ts, hi, lo });
    }

    fn redisInteger(resp: RespValue) !i64 {
        return switch (resp) {
            .integer => |n| n,
            .bulk_string => |maybe_s| if (maybe_s) |s| std.fmt.parseInt(i64, s, 10) catch return error.InvalidResp else return error.InvalidResp,
            .simple_string => |s| std.fmt.parseInt(i64, s, 10) catch return error.InvalidResp,
            else => error.InvalidResp,
        };
    }

    fn getMetaU64(self: *Self, field: []const u8) !u64 {
        const meta_key = try self.feedMetaKey();
        defer self.allocator.free(meta_key);
        var resp = try self.sendCommand(&.{ "HGET", meta_key, field });
        defer resp.deinit(self.allocator);
        const text = resp.asString() orelse return 0;
        return std.fmt.parseInt(u64, text, 10) catch 0;
    }

    fn setMetaU64(self: *Self, field: []const u8, value: u64) !void {
        const meta_key = try self.feedMetaKey();
        defer self.allocator.free(meta_key);
        var value_buf: [32]u8 = undefined;
        const value_str = std.fmt.bufPrint(&value_buf, "{d}", .{value}) catch unreachable;
        var resp = try self.sendCommand(&.{ "HSET", meta_key, field, value_str });
        resp.deinit(self.allocator);
    }

    fn getFrontier(self: *Self, origin_instance_id: []const u8) !u64 {
        const key = try self.feedFrontiersKey();
        defer self.allocator.free(key);
        var resp = try self.sendCommand(&.{ "HGET", key, origin_instance_id });
        defer resp.deinit(self.allocator);
        const text = resp.asString() orelse return 0;
        return std.fmt.parseInt(u64, text, 10) catch 0;
    }

    fn setFrontier(self: *Self, origin_instance_id: []const u8, origin_sequence: u64) !void {
        const current = try self.getFrontier(origin_instance_id);
        if (origin_sequence <= current) return;
        const key = try self.feedFrontiersKey();
        defer self.allocator.free(key);
        var value_buf: [32]u8 = undefined;
        const value_str = std.fmt.bufPrint(&value_buf, "{d}", .{origin_sequence}) catch unreachable;
        var resp = try self.sendCommand(&.{ "HSET", key, origin_instance_id, value_str });
        resp.deinit(self.allocator);
    }

    fn nextLocalOriginSequence(self: *Self) !u64 {
        return (try self.getFrontier(self.localInstanceId())) + 1;
    }

    fn nextEventSequence(self: *Self) !u64 {
        const meta_key = try self.feedMetaKey();
        defer self.allocator.free(meta_key);
        var resp = try self.sendCommand(&.{ "HINCRBY", meta_key, "last_sequence", "1" });
        defer resp.deinit(self.allocator);
        const next = try redisInteger(resp);
        if (next < 0) return error.InvalidResp;
        return @intCast(next);
    }

    const BackfillRecord = struct {
        storage_key: []u8,
        record: StoredRecord,

        fn deinit(self: *BackfillRecord, allocator: std.mem.Allocator) void {
            allocator.free(self.storage_key);
            self.record.deinit(allocator);
        }
    };

    fn backfillFeedFromExistingState(self: *Self) !void {
        if (try self.getMetaU64("last_sequence") != 0) return;

        const keys_set = try self.prefixedSimple("keys");
        defer self.allocator.free(keys_set);
        var keys_resp = try self.sendCommandAlloc(self.allocator, &.{ "SMEMBERS", keys_set });
        defer keys_resp.deinit(self.allocator);
        const keys = switch (keys_resp) {
            .array => |maybe_arr| maybe_arr orelse return,
            else => return,
        };
        if (keys.len == 0) return;

        var records: std.ArrayListUnmanaged(BackfillRecord) = .empty;
        defer {
            for (records.items) |*item| item.deinit(self.allocator);
            records.deinit(self.allocator);
        }

        for (keys) |kv| {
            const storage_key = kv.asString() orelse continue;
            const record = try getStoredRecordByStorageKey(self, self.allocator, storage_key) orelse continue;
            try records.append(self.allocator, .{
                .storage_key = try self.allocator.dupe(u8, storage_key),
                .record = record,
            });
        }

        std.mem.sort(BackfillRecord, records.items, {}, struct {
            fn lessThan(_: void, a: BackfillRecord, b: BackfillRecord) bool {
                if (a.record.event_timestamp_ms != b.record.event_timestamp_ms) {
                    return a.record.event_timestamp_ms < b.record.event_timestamp_ms;
                }
                const origin_order = std.mem.order(u8, a.record.event_origin_instance_id, b.record.event_origin_instance_id);
                if (origin_order != .eq) return origin_order == .lt;
                if (a.record.event_origin_sequence != b.record.event_origin_sequence) {
                    return a.record.event_origin_sequence < b.record.event_origin_sequence;
                }
                const key_order = std.mem.order(u8, a.record.entry.key, b.record.entry.key);
                if (key_order != .eq) return key_order == .lt;
                return std.mem.order(u8, a.storage_key, b.storage_key) == .lt;
            }
        }.lessThan);

        for (records.items) |item| {
            const input: MemoryEventInput = .{
                .origin_instance_id = item.record.event_origin_instance_id,
                .origin_sequence = item.record.event_origin_sequence,
                .timestamp_ms = item.record.event_timestamp_ms,
                .operation = .put,
                .key = item.record.entry.key,
                .session_id = item.record.entry.session_id,
                .category = item.record.entry.category,
                .value_kind = item.record.value_kind,
                .content = item.record.entry.content,
            };
            try appendNativeEvent(self, input);
            try self.setFrontier(input.origin_instance_id, input.origin_sequence);
        }
    }

    // ── Memory vtable implementation ───────────────────────────────

    fn implName(_: *anyopaque) []const u8 {
        return "redis";
    }

    fn implStore(ptr: *anyopaque, key: []const u8, content: []const u8, category: MemoryCategory, session_id: ?[]const u8) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try emitLocalEvent(self_, .put, key, session_id, category, null, content);
    }

    fn implGet(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const storage_key = try key_codec.encode(allocator, key, null);
        defer allocator.free(storage_key);

        const entry_key = try self_.prefixedKey("entry", storage_key);
        defer self_.allocator.free(entry_key);

        var resp = try self_.sendCommandAlloc(allocator, &.{ "HGETALL", entry_key });
        defer resp.deinit(allocator);

        const fields = switch (resp) {
            .array => |maybe_arr| maybe_arr orelse return null,
            else => return null,
        };

        if (fields.len == 0) return null;

        return try parseHashFields(allocator, storage_key, fields);
    }

    fn implGetScoped(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8) anyerror!?MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const storage_key = try key_codec.encode(allocator, key, session_id);
        defer allocator.free(storage_key);

        const entry_key = try self_.prefixedKey("entry", storage_key);
        defer self_.allocator.free(entry_key);

        var resp = try self_.sendCommandAlloc(allocator, &.{ "HGETALL", entry_key });
        defer resp.deinit(allocator);

        const fields = switch (resp) {
            .array => |maybe_arr| maybe_arr orelse return null,
            else => return null,
        };
        if (fields.len == 0) return null;

        return try parseHashFields(allocator, storage_key, fields);
    }

    fn implRecall(ptr: *anyopaque, allocator: std.mem.Allocator, query: []const u8, limit: usize, session_id: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const trimmed = std.mem.trim(u8, query, " \t\n\r");
        if (trimmed.len == 0) return allocator.alloc(MemoryEntry, 0);

        // Get all keys
        const keys_set = try self_.prefixedSimple("keys");
        defer self_.allocator.free(keys_set);

        var keys_resp = try self_.sendCommandAlloc(allocator, &.{ "SMEMBERS", keys_set });
        defer keys_resp.deinit(allocator);

        const key_values = switch (keys_resp) {
            .array => |maybe_arr| maybe_arr orelse return allocator.alloc(MemoryEntry, 0),
            else => return allocator.alloc(MemoryEntry, 0),
        };

        var entries: std.ArrayList(MemoryEntry) = .empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }

        const lower_query = try std.ascii.allocLowerString(allocator, trimmed);
        defer allocator.free(lower_query);

        for (key_values) |kv| {
            const k = kv.asString() orelse continue;

            const entry_key = try self_.prefixedKey("entry", k);
            defer self_.allocator.free(entry_key);

            var hash_resp = try self_.sendCommandAlloc(allocator, &.{ "HGETALL", entry_key });
            defer hash_resp.deinit(allocator);

            const fields = switch (hash_resp) {
                .array => |maybe_arr| maybe_arr orelse continue,
                else => continue,
            };
            if (fields.len == 0) continue;

            var entry = try parseHashFields(allocator, k, fields);
            errdefer entry.deinit(allocator);

            // Filter by session_id if provided
            if (session_id) |sid| {
                if (entry.session_id) |e_sid| {
                    if (!std.mem.eql(u8, e_sid, sid)) {
                        entry.deinit(allocator);
                        continue;
                    }
                } else {
                    entry.deinit(allocator);
                    continue;
                }
            }

            // Substring search (case-insensitive)
            const lower_content = try std.ascii.allocLowerString(allocator, entry.content);
            defer allocator.free(lower_content);
            const lower_key = try std.ascii.allocLowerString(allocator, entry.key);
            defer allocator.free(lower_key);

            const key_match = std.mem.indexOf(u8, lower_key, lower_query) != null;
            const content_match = std.mem.indexOf(u8, lower_content, lower_query) != null;

            if (key_match or content_match) {
                // Score: key match = 2.0, content match = 1.0
                var score: f64 = 0;
                if (key_match) score += 2.0;
                if (content_match) score += 1.0;
                entry.score = score;
                try entries.append(allocator, entry);
            } else {
                entry.deinit(allocator);
            }
        }

        // Sort by updated_at descending, then by score descending
        std.mem.sort(MemoryEntry, entries.items, {}, struct {
            fn lessThan(_: void, a: MemoryEntry, b: MemoryEntry) bool {
                // Higher score first
                const sa = a.score orelse 0;
                const sb = b.score orelse 0;
                if (sa != sb) return sa > sb;
                // Then by timestamp descending
                return std.mem.order(u8, a.timestamp, b.timestamp) == .gt;
            }
        }.lessThan);

        // Truncate to limit
        if (entries.items.len > limit) {
            for (entries.items[limit..]) |*entry| entry.deinit(allocator);
            entries.shrinkRetainingCapacity(limit);
        }

        return entries.toOwnedSlice(allocator);
    }

    fn implList(ptr: *anyopaque, allocator: std.mem.Allocator, category: ?MemoryCategory, session_id: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        // Determine which set to query
        const set_key = if (category) |cat|
            try self_.prefixedKey("cat", cat.toString())
        else
            try self_.prefixedSimple("keys");
        defer self_.allocator.free(set_key);

        var keys_resp = try self_.sendCommandAlloc(allocator, &.{ "SMEMBERS", set_key });
        defer keys_resp.deinit(allocator);

        const key_values = switch (keys_resp) {
            .array => |maybe_arr| maybe_arr orelse return allocator.alloc(MemoryEntry, 0),
            else => return allocator.alloc(MemoryEntry, 0),
        };

        var entries: std.ArrayList(MemoryEntry) = .empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }

        for (key_values) |kv| {
            const k = kv.asString() orelse continue;

            const entry_key = try self_.prefixedKey("entry", k);
            defer self_.allocator.free(entry_key);

            var hash_resp = try self_.sendCommandAlloc(allocator, &.{ "HGETALL", entry_key });
            defer hash_resp.deinit(allocator);

            const fields = switch (hash_resp) {
                .array => |maybe_arr| maybe_arr orelse continue,
                else => continue,
            };
            if (fields.len == 0) continue;

            var entry = try parseHashFields(allocator, k, fields);
            errdefer entry.deinit(allocator);

            // Filter by session_id if provided
            if (session_id) |sid| {
                if (entry.session_id) |e_sid| {
                    if (!std.mem.eql(u8, e_sid, sid)) {
                        entry.deinit(allocator);
                        continue;
                    }
                } else {
                    entry.deinit(allocator);
                    continue;
                }
            }

            try entries.append(allocator, entry);
        }

        return entries.toOwnedSlice(allocator);
    }

    fn implForget(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        const keys_set = try self_.prefixedSimple("keys");
        defer self_.allocator.free(keys_set);
        var keys_resp = try self_.sendCommandAlloc(self_.allocator, &.{ "SMEMBERS", keys_set });
        defer keys_resp.deinit(self_.allocator);
        const storage_keys = switch (keys_resp) {
            .array => |maybe_arr| maybe_arr orelse return false,
            else => return false,
        };
        for (storage_keys) |kv| {
            const storage_key = kv.asString() orelse continue;
            const decoded = key_codec.decode(storage_key);
            if (std.mem.eql(u8, decoded.logical_key, key)) {
                try emitLocalEvent(self_, .delete_all, key, null, null, null, null);
                return true;
            }
        }
        return false;
    }

    fn implForgetScoped(ptr: *anyopaque, key: []const u8, session_id: ?[]const u8) anyerror!bool {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        const storage_key = try key_codec.encode(self_.allocator, key, session_id);
        defer self_.allocator.free(storage_key);
        const exists = try getStoredRecordByStorageKey(self_, self_.allocator, storage_key);
        if (exists) |record| {
            var mutable = record;
            defer mutable.deinit(self_.allocator);
            try emitLocalEvent(self_, .delete_scoped, key, session_id, null, null, null);
            return true;
        }
        return false;
    }

    fn implListEvents(ptr: *anyopaque, allocator: std.mem.Allocator, after_sequence: u64, limit: usize) anyerror![]MemoryEvent {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        const compacted_through = try self_.getMetaU64("compacted_through_sequence");
        if (after_sequence < compacted_through) return error.CursorExpired;

        const stream_key = try self_.feedEventsKey();
        defer self_.allocator.free(stream_key);
        var start_buf: [32]u8 = undefined;
        const start_id = std.fmt.bufPrint(&start_buf, "{d}-0", .{after_sequence + 1}) catch unreachable;
        var count_buf: [32]u8 = undefined;
        const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{limit}) catch unreachable;
        var resp = try self_.sendCommandAlloc(allocator, &.{ "XRANGE", stream_key, start_id, "+", "COUNT", count_str });
        defer resp.deinit(allocator);

        const stream_entries = switch (resp) {
            .array => |maybe_arr| maybe_arr orelse return allocator.alloc(MemoryEvent, 0),
            else => return allocator.alloc(MemoryEvent, 0),
        };

        var events: std.ArrayListUnmanaged(MemoryEvent) = .empty;
        errdefer {
            for (events.items) |*event| event.deinit(allocator);
            events.deinit(allocator);
        }

        for (stream_entries) |entry_val| {
            const entry_arr = switch (entry_val) {
                .array => |maybe_arr| maybe_arr orelse continue,
                else => continue,
            };
            if (entry_arr.len != 2) continue;
            const id_text = entry_arr[0].asString() orelse continue;
            const dash = std.mem.indexOfScalar(u8, id_text, '-') orelse continue;
            const sequence = std.fmt.parseInt(u64, id_text[0..dash], 10) catch continue;
            const fields = switch (entry_arr[1]) {
                .array => |maybe_arr| maybe_arr orelse continue,
                else => continue,
            };
            const origin_instance_id = getHashFieldString(fields, "origin_instance_id") orelse continue;
            const origin_sequence = std.fmt.parseInt(u64, getHashFieldString(fields, "origin_sequence") orelse "0", 10) catch continue;
            const timestamp_ms = std.fmt.parseInt(i64, getHashFieldString(fields, "timestamp_ms") orelse "0", 10) catch continue;
            const operation = root.MemoryEventOp.fromString(getHashFieldString(fields, "operation") orelse "") orelse continue;
            const key = getHashFieldString(fields, "key") orelse continue;
            const session_id = getHashFieldString(fields, "session_id");
            const category_text = getHashFieldString(fields, "category");
            const value_kind_text = getHashFieldString(fields, "value_kind");
            const content = getHashFieldString(fields, "content");

            try events.append(allocator, .{
                .schema_version = @intCast(std.fmt.parseInt(u32, getHashFieldString(fields, "schema_version") orelse "1", 10) catch 1),
                .sequence = sequence,
                .origin_instance_id = try allocator.dupe(u8, origin_instance_id),
                .origin_sequence = origin_sequence,
                .timestamp_ms = timestamp_ms,
                .operation = operation,
                .key = try allocator.dupe(u8, key),
                .session_id = if (session_id) |sid| if (sid.len > 0) try allocator.dupe(u8, sid) else null else null,
                .category = if (category_text) |cat| if (cat.len > 0) try root.cloneMemoryCategory(allocator, MemoryCategory.fromString(cat)) else null else null,
                .value_kind = if (value_kind_text) |kind| if (kind.len > 0) MemoryValueKind.fromString(kind) else null else null,
                .content = if (content) |text| if (text.len > 0) try allocator.dupe(u8, text) else null else null,
            });
        }

        return events.toOwnedSlice(allocator);
    }

    fn implApplyEvent(ptr: *anyopaque, input: MemoryEventInput) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try applyEventInternal(self_, input);
    }

    fn implLastEventSequence(ptr: *anyopaque) anyerror!u64 {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        return self_.getMetaU64("last_sequence");
    }

    fn implEventFeedInfo(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!MemoryEventFeedInfo {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        const compacted_through = try self_.getMetaU64("compacted_through_sequence");
        return .{
            .instance_id = try allocator.dupe(u8, self_.localInstanceId()),
            .last_sequence = try self_.getMetaU64("last_sequence"),
            .next_local_origin_sequence = try self_.nextLocalOriginSequence(),
            .supports_compaction = true,
            .storage_kind = .native,
            .compacted_through_sequence = compacted_through,
            .oldest_available_sequence = compacted_through + 1,
        };
    }

    fn implCompactEvents(ptr: *anyopaque) anyerror!u64 {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        const stream_key = try self_.feedEventsKey();
        defer self_.allocator.free(stream_key);
        const compacted_through = try self_.getMetaU64("last_sequence");

        var cursor: u64 = 0;
        while (cursor < compacted_through) {
            const start = cursor + 1;
            var start_buf: [32]u8 = undefined;
            const start_id = std.fmt.bufPrint(&start_buf, "{d}-0", .{start}) catch unreachable;
            var end_buf: [32]u8 = undefined;
            const end_id = std.fmt.bufPrint(&end_buf, "{d}-0", .{compacted_through}) catch unreachable;
            var resp = try self_.sendCommandAlloc(self_.allocator, &.{ "XRANGE", stream_key, start_id, end_id, "COUNT", "128" });
            defer resp.deinit(self_.allocator);
            const stream_entries = switch (resp) {
                .array => |maybe_arr| maybe_arr orelse break,
                else => break,
            };
            if (stream_entries.len == 0) break;
            for (stream_entries) |entry_val| {
                const entry_arr = switch (entry_val) {
                    .array => |maybe_arr| maybe_arr orelse continue,
                    else => continue,
                };
                if (entry_arr.len < 1) continue;
                const id_text = entry_arr[0].asString() orelse continue;
                var del_resp = try self_.sendCommand(&.{ "XDEL", stream_key, id_text });
                del_resp.deinit(self_.allocator);
                const dash = std.mem.indexOfScalar(u8, id_text, '-') orelse continue;
                cursor = std.fmt.parseInt(u64, id_text[0..dash], 10) catch cursor;
            }
        }

        try self_.setMetaU64("compacted_through_sequence", compacted_through);
        return compacted_through;
    }

    fn implExportCheckpoint(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        const last_sequence = try self_.getMetaU64("last_sequence");
        const compacted_through = try self_.getMetaU64("compacted_through_sequence");
        var last_timestamp_ms: i64 = 0;

        try out.append(allocator, '{');
        try json_util.appendJsonKeyValue(&out, allocator, "kind", "meta");
        try out.append(allocator, ',');
        try json_util.appendJsonInt(&out, allocator, "schema_version", 1);
        try out.append(allocator, ',');
        try json_util.appendJsonKey(&out, allocator, "last_sequence");
        try out.writer(allocator).print("{d}", .{last_sequence});
        try out.append(allocator, ',');
        try json_util.appendJsonKey(&out, allocator, "last_timestamp_ms");
        try out.writer(allocator).print("{d}", .{last_timestamp_ms});
        try out.append(allocator, ',');
        try json_util.appendJsonKey(&out, allocator, "compacted_through_sequence");
        try out.writer(allocator).print("{d}", .{compacted_through});
        try out.appendSlice(allocator, "}\n");

        const frontiers_key = try self_.feedFrontiersKey();
        defer self_.allocator.free(frontiers_key);
        var frontiers_resp = try self_.sendCommandAlloc(allocator, &.{ "HGETALL", frontiers_key });
        defer frontiers_resp.deinit(allocator);
        const frontiers = switch (frontiers_resp) {
            .array => |maybe_arr| maybe_arr orelse &.{},
            else => &.{},
        };
        var idx: usize = 0;
        while (idx + 1 < frontiers.len) : (idx += 2) {
            const origin = frontiers[idx].asString() orelse continue;
            const seq = frontiers[idx + 1].asString() orelse continue;
            try out.append(allocator, '{');
            try json_util.appendJsonKeyValue(&out, allocator, "kind", "frontier");
            try out.append(allocator, ',');
            try json_util.appendJsonKeyValue(&out, allocator, "origin_instance_id", origin);
            try out.append(allocator, ',');
            try json_util.appendJsonKey(&out, allocator, "origin_sequence");
            try out.appendSlice(allocator, seq);
            try out.appendSlice(allocator, "}\n");
        }

        const keys_set = try self_.prefixedSimple("keys");
        defer self_.allocator.free(keys_set);
        var keys_resp = try self_.sendCommandAlloc(allocator, &.{ "SMEMBERS", keys_set });
        defer keys_resp.deinit(allocator);
        const keys = switch (keys_resp) {
            .array => |maybe_arr| maybe_arr orelse &.{},
            else => &.{},
        };
        for (keys) |kv| {
            const storage_key = kv.asString() orelse continue;
            const record = try getStoredRecordByStorageKey(self_, allocator, storage_key) orelse continue;
            defer {
                var mutable = record;
                mutable.deinit(allocator);
            }
            last_timestamp_ms = @max(last_timestamp_ms, record.event_timestamp_ms);
            try out.append(allocator, '{');
            try json_util.appendJsonKeyValue(&out, allocator, "kind", "state");
            try out.append(allocator, ',');
            try json_util.appendJsonKeyValue(&out, allocator, "key", record.entry.key);
            try out.append(allocator, ',');
            try json_util.appendJsonKey(&out, allocator, "session_id");
            if (record.entry.session_id) |sid| {
                try json_util.appendJsonString(&out, allocator, sid);
            } else {
                try out.appendSlice(allocator, "null");
            }
            try out.append(allocator, ',');
            try json_util.appendJsonKeyValue(&out, allocator, "category", record.entry.category.toString());
            try out.append(allocator, ',');
            try json_util.appendJsonKey(&out, allocator, "value_kind");
            if (record.value_kind) |kind| {
                try json_util.appendJsonString(&out, allocator, kind.toString());
            } else {
                try out.appendSlice(allocator, "null");
            }
            try out.append(allocator, ',');
            try json_util.appendJsonKeyValue(&out, allocator, "content", record.entry.content);
            try out.append(allocator, ',');
            try json_util.appendJsonKey(&out, allocator, "timestamp_ms");
            try out.writer(allocator).print("{d}", .{record.event_timestamp_ms});
            try out.append(allocator, ',');
            try json_util.appendJsonKeyValue(&out, allocator, "origin_instance_id", record.event_origin_instance_id);
            try out.append(allocator, ',');
            try json_util.appendJsonKey(&out, allocator, "origin_sequence");
            try out.writer(allocator).print("{d}", .{record.event_origin_sequence});
            try out.appendSlice(allocator, "}\n");
        }

        const scoped_index = try self_.tombScopedIndexKey();
        defer self_.allocator.free(scoped_index);
        var scoped_resp = try self_.sendCommandAlloc(allocator, &.{ "SMEMBERS", scoped_index });
        defer scoped_resp.deinit(allocator);
        const scoped_keys = switch (scoped_resp) {
            .array => |maybe_arr| maybe_arr orelse &.{},
            else => &.{},
        };
        for (scoped_keys) |kv| {
            const tomb_name = kv.asString() orelse continue;
            const meta = try getTombstoneMeta(self_, allocator, tomb_name, true) orelse continue;
            defer meta.deinit(allocator);
            last_timestamp_ms = @max(last_timestamp_ms, meta.timestamp_ms);
            try out.append(allocator, '{');
            try json_util.appendJsonKeyValue(&out, allocator, "kind", "scoped_tombstone");
            try out.append(allocator, ',');
            try json_util.appendJsonKeyValue(&out, allocator, "key", tomb_name);
            try out.append(allocator, ',');
            try json_util.appendJsonKey(&out, allocator, "timestamp_ms");
            try out.writer(allocator).print("{d}", .{meta.timestamp_ms});
            try out.append(allocator, ',');
            try json_util.appendJsonKeyValue(&out, allocator, "origin_instance_id", meta.origin_instance_id);
            try out.append(allocator, ',');
            try json_util.appendJsonKey(&out, allocator, "origin_sequence");
            try out.writer(allocator).print("{d}", .{meta.origin_sequence});
            try out.appendSlice(allocator, "}\n");
        }

        const key_index = try self_.tombKeyIndexKey();
        defer self_.allocator.free(key_index);
        var key_resp = try self_.sendCommandAlloc(allocator, &.{ "SMEMBERS", key_index });
        defer key_resp.deinit(allocator);
        const key_keys = switch (key_resp) {
            .array => |maybe_arr| maybe_arr orelse &.{},
            else => &.{},
        };
        for (key_keys) |kv| {
            const key_name = kv.asString() orelse continue;
            const meta = try getTombstoneMeta(self_, allocator, key_name, false) orelse continue;
            defer meta.deinit(allocator);
            last_timestamp_ms = @max(last_timestamp_ms, meta.timestamp_ms);
            try out.append(allocator, '{');
            try json_util.appendJsonKeyValue(&out, allocator, "kind", "key_tombstone");
            try out.append(allocator, ',');
            try json_util.appendJsonKeyValue(&out, allocator, "key", key_name);
            try out.append(allocator, ',');
            try json_util.appendJsonKey(&out, allocator, "timestamp_ms");
            try out.writer(allocator).print("{d}", .{meta.timestamp_ms});
            try out.append(allocator, ',');
            try json_util.appendJsonKeyValue(&out, allocator, "origin_instance_id", meta.origin_instance_id);
            try out.append(allocator, ',');
            try json_util.appendJsonKey(&out, allocator, "origin_sequence");
            try out.writer(allocator).print("{d}", .{meta.origin_sequence});
            try out.appendSlice(allocator, "}\n");
        }

        return out.toOwnedSlice(allocator);
    }

    fn implApplyCheckpoint(ptr: *anyopaque, payload: []const u8) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try clearRedisFeedAndProjection(self_);

        var last_sequence: u64 = 0;
        var compacted_through: u64 = 0;
        var lines = std.mem.splitScalar(u8, payload, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r\n");
            if (line.len == 0) continue;

            var parsed = try std.json.parseFromSlice(std.json.Value, self_.allocator, line, .{});
            defer parsed.deinit();
            const kind = memoryJsonString(parsed.value, "kind") orelse return error.InvalidEvent;

            if (std.mem.eql(u8, kind, "meta")) {
                last_sequence = memoryJsonUnsigned(parsed.value, "last_sequence") orelse 0;
                compacted_through = memoryJsonUnsigned(parsed.value, "compacted_through_sequence") orelse last_sequence;
                continue;
            }
            if (std.mem.eql(u8, kind, "frontier")) {
                const origin = memoryJsonString(parsed.value, "origin_instance_id") orelse return error.InvalidEvent;
                const seq = memoryJsonUnsigned(parsed.value, "origin_sequence") orelse return error.InvalidEvent;
                try self_.setFrontier(origin, seq);
                continue;
            }
            if (std.mem.eql(u8, kind, "state")) {
                const key = memoryJsonString(parsed.value, "key") orelse return error.InvalidEvent;
                const content = memoryJsonString(parsed.value, "content") orelse return error.InvalidEvent;
                const category = MemoryCategory.fromString(memoryJsonString(parsed.value, "category") orelse return error.InvalidEvent);
                const session_id = memoryJsonNullableString(parsed.value, "session_id");
                const value_kind = if (memoryJsonNullableString(parsed.value, "value_kind")) |value|
                    MemoryValueKind.fromString(value) orelse return error.InvalidEvent
                else
                    null;
                const input: MemoryEventInput = .{
                    .origin_instance_id = memoryJsonString(parsed.value, "origin_instance_id") orelse return error.InvalidEvent,
                    .origin_sequence = memoryJsonUnsigned(parsed.value, "origin_sequence") orelse return error.InvalidEvent,
                    .timestamp_ms = memoryJsonInteger(parsed.value, "timestamp_ms") orelse return error.InvalidEvent,
                    .operation = .put,
                    .key = key,
                    .session_id = session_id,
                    .category = category,
                    .value_kind = value_kind,
                    .content = content,
                };
                try upsertProjection(self_, key, content, category, value_kind, session_id, input);
                continue;
            }
            if (std.mem.eql(u8, kind, "scoped_tombstone")) {
                const encoded_key = memoryJsonString(parsed.value, "key") orelse return error.InvalidEvent;
                const decoded = key_codec.decode(encoded_key);
                if (decoded.is_legacy) return error.InvalidEvent;
                const input: MemoryEventInput = .{
                    .origin_instance_id = memoryJsonString(parsed.value, "origin_instance_id") orelse return error.InvalidEvent,
                    .origin_sequence = memoryJsonUnsigned(parsed.value, "origin_sequence") orelse return error.InvalidEvent,
                    .timestamp_ms = memoryJsonInteger(parsed.value, "timestamp_ms") orelse return error.InvalidEvent,
                    .operation = .delete_scoped,
                    .key = decoded.logical_key,
                    .session_id = decoded.session_id,
                };
                try upsertTombstone(self_, decoded.logical_key, true, decoded.session_id, input);
                continue;
            }
            if (std.mem.eql(u8, kind, "key_tombstone")) {
                const key = memoryJsonString(parsed.value, "key") orelse return error.InvalidEvent;
                const input: MemoryEventInput = .{
                    .origin_instance_id = memoryJsonString(parsed.value, "origin_instance_id") orelse return error.InvalidEvent,
                    .origin_sequence = memoryJsonUnsigned(parsed.value, "origin_sequence") orelse return error.InvalidEvent,
                    .timestamp_ms = memoryJsonInteger(parsed.value, "timestamp_ms") orelse return error.InvalidEvent,
                    .operation = .delete_all,
                    .key = key,
                };
                try upsertTombstone(self_, key, false, null, input);
                continue;
            }
            return error.InvalidEvent;
        }

        try self_.setMetaU64("last_sequence", last_sequence);
        try self_.setMetaU64("compacted_through_sequence", compacted_through);
    }

    fn implCount(ptr: *anyopaque) anyerror!usize {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const keys_set = try self_.prefixedSimple("keys");
        defer self_.allocator.free(keys_set);

        var resp = try self_.sendCommand(&.{ "SCARD", keys_set });
        defer resp.deinit(self_.allocator);

        return switch (resp) {
            .integer => |n| if (n >= 0) @intCast(n) else 0,
            else => 0,
        };
    }

    fn implHealthCheck(ptr: *anyopaque) bool {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        var resp = self_.sendCommand(&.{"PING"}) catch return false;
        defer resp.deinit(self_.allocator);
        return switch (resp) {
            .simple_string => |s| std.mem.eql(u8, s, "PONG"),
            else => false,
        };
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

// ── Hash field parser ──────────────────────────────────────────────

fn parseHashFields(allocator: std.mem.Allocator, stored_key: []const u8, fields: []RespValue) !MemoryEntry {
    // HGETALL returns [field, value, field, value, ...]
    const decoded = key_codec.decode(stored_key);
    var id_val: ?[]const u8 = null;
    var content_val: ?[]const u8 = null;
    var category_val: ?[]const u8 = null;
    var session_id_val: ?[]const u8 = null;
    var timestamp_val: ?[]const u8 = null;

    var i: usize = 0;
    while (i + 1 < fields.len) : (i += 2) {
        const field_name = fields[i].asString() orelse continue;
        const field_value = fields[i + 1].asString() orelse continue;

        if (std.mem.eql(u8, field_name, "id")) {
            id_val = field_value;
        } else if (std.mem.eql(u8, field_name, "content")) {
            content_val = field_value;
        } else if (std.mem.eql(u8, field_name, "category")) {
            category_val = field_value;
        } else if (std.mem.eql(u8, field_name, "session_id")) {
            session_id_val = field_value;
        } else if (std.mem.eql(u8, field_name, "updated_at")) {
            timestamp_val = field_value;
        }
    }

    const id = try allocator.dupe(u8, id_val orelse "");
    errdefer allocator.free(id);
    const entry_key = try allocator.dupe(u8, decoded.logical_key);
    errdefer allocator.free(entry_key);
    const content = try allocator.dupe(u8, content_val orelse "");
    errdefer allocator.free(content);
    const timestamp = try allocator.dupe(u8, timestamp_val orelse "0");
    errdefer allocator.free(timestamp);

    const cat_str = category_val orelse "core";
    const category = MemoryCategory.fromString(cat_str);
    // If category is .custom, we need to dupe the string since it points into the resp buffer
    const final_category: MemoryCategory = switch (category) {
        .custom => .{ .custom = try allocator.dupe(u8, cat_str) },
        else => category,
    };

    var sid: ?[]const u8 = null;
    if (decoded.session_id) |decoded_sid| {
        sid = try allocator.dupe(u8, decoded_sid);
    } else if (session_id_val) |sv| {
        if (sv.len > 0) {
            sid = try allocator.dupe(u8, sv);
        }
    }

    return .{
        .id = id,
        .key = entry_key,
        .content = content,
        .category = final_category,
        .timestamp = timestamp,
        .session_id = sid,
    };
}

const StoredRecord = struct {
    entry: MemoryEntry,
    value_kind: ?MemoryValueKind = null,
    event_timestamp_ms: i64 = 0,
    event_origin_instance_id: []u8,
    event_origin_sequence: u64 = 0,

    fn deinit(self: *StoredRecord, allocator: std.mem.Allocator) void {
        self.entry.deinit(allocator);
        allocator.free(self.event_origin_instance_id);
    }
};

const TombstoneMeta = struct {
    timestamp_ms: i64,
    origin_instance_id: []u8,
    origin_sequence: u64,

    fn deinit(self: *const TombstoneMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.origin_instance_id);
    }
};

fn memoryJsonString(val: std.json.Value, key: []const u8) ?[]const u8 {
    if (val != .object) return null;
    const field = val.object.get(key) orelse return null;
    return switch (field) {
        .string => |s| s,
        else => null,
    };
}

fn memoryJsonNullableString(val: std.json.Value, key: []const u8) ?[]const u8 {
    if (val != .object) return null;
    const field = val.object.get(key) orelse return null;
    return switch (field) {
        .null => null,
        .string => |s| s,
        else => null,
    };
}

fn memoryJsonInteger(val: std.json.Value, key: []const u8) ?i64 {
    if (val != .object) return null;
    const field = val.object.get(key) orelse return null;
    return switch (field) {
        .integer => |n| n,
        else => null,
    };
}

fn memoryJsonUnsigned(val: std.json.Value, key: []const u8) ?u64 {
    const value = memoryJsonInteger(val, key) orelse return null;
    if (value < 0) return null;
    return @intCast(value);
}

fn getHashFieldString(fields: []RespValue, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < fields.len) : (i += 2) {
        const field_name = fields[i].asString() orelse continue;
        if (std.mem.eql(u8, field_name, name)) {
            return fields[i + 1].asString();
        }
    }
    return null;
}

fn parseHashRecord(allocator: std.mem.Allocator, stored_key: []const u8, fields: []RespValue) !StoredRecord {
    var entry = try parseHashFields(allocator, stored_key, fields);
    errdefer entry.deinit(allocator);

    const value_kind_text = getHashFieldString(fields, "value_kind");
    const ts_text = getHashFieldString(fields, "event_timestamp_ms") orelse "0";
    const origin_text = getHashFieldString(fields, "event_origin_instance_id") orelse "default";
    const origin_seq_text = getHashFieldString(fields, "event_origin_sequence") orelse "0";

    return .{
        .entry = entry,
        .value_kind = if (value_kind_text) |text| MemoryValueKind.fromString(text) else null,
        .event_timestamp_ms = std.fmt.parseInt(i64, ts_text, 10) catch 0,
        .event_origin_instance_id = try allocator.dupe(u8, origin_text),
        .event_origin_sequence = std.fmt.parseInt(u64, origin_seq_text, 10) catch 0,
    };
}

fn getStoredRecordByStorageKey(self: *RedisMemory, allocator: std.mem.Allocator, storage_key: []const u8) !?StoredRecord {
    const entry_key = try RedisMemory.prefixedKey(self, "entry", storage_key);
    defer self.allocator.free(entry_key);

    var resp = try RedisMemory.sendCommandAlloc(self, allocator, &.{ "HGETALL", entry_key });
    defer resp.deinit(allocator);

    const fields = switch (resp) {
        .array => |maybe_arr| maybe_arr orelse return null,
        else => return null,
    };
    if (fields.len == 0) return null;
    return @as(?StoredRecord, try parseHashRecord(allocator, storage_key, fields));
}

fn getTombstoneMeta(self: *RedisMemory, allocator: std.mem.Allocator, key: []const u8, scoped: bool) !?TombstoneMeta {
    const tomb_key = if (scoped)
        try self.tombScopedKey(key)
    else
        try self.tombKeyKey(key);
    defer self.allocator.free(tomb_key);

    var resp = try self.sendCommandAlloc(allocator, &.{ "HGETALL", tomb_key });
    defer resp.deinit(allocator);
    const fields = switch (resp) {
        .array => |maybe_arr| maybe_arr orelse return null,
        else => return null,
    };
    if (fields.len == 0) return null;
    const ts_text = getHashFieldString(fields, "timestamp_ms") orelse return null;
    const origin_text = getHashFieldString(fields, "origin_instance_id") orelse return null;
    const origin_seq_text = getHashFieldString(fields, "origin_sequence") orelse return null;
    return .{
        .timestamp_ms = std.fmt.parseInt(i64, ts_text, 10) catch 0,
        .origin_instance_id = try allocator.dupe(u8, origin_text),
        .origin_sequence = std.fmt.parseInt(u64, origin_seq_text, 10) catch 0,
    };
}

fn upsertProjection(self: *RedisMemory, key: []const u8, content: []const u8, category: MemoryCategory, value_kind: ?MemoryValueKind, session_id: ?[]const u8, input: MemoryEventInput) !void {
    const now = try RedisMemory.getNowTimestamp(self.allocator);
    defer self.allocator.free(now);
    const id = try RedisMemory.generateId(self.allocator);
    defer self.allocator.free(id);
    const cat_str = category.toString();
    const storage_key = try key_codec.encode(self.allocator, key, session_id);
    defer self.allocator.free(storage_key);

    const entry_key = try RedisMemory.prefixedKey(self, "entry", storage_key);
    defer self.allocator.free(entry_key);

    var old_cat_resp = try RedisMemory.sendCommand(self, &.{ "HGET", entry_key, "category" });
    const old_cat_str = old_cat_resp.asString();
    defer old_cat_resp.deinit(self.allocator);
    var old_sid_resp = try RedisMemory.sendCommand(self, &.{ "HGET", entry_key, "session_id" });
    const old_sid_str = old_sid_resp.asString();
    defer old_sid_resp.deinit(self.allocator);

    if (old_cat_str) |old_cat| {
        if (old_cat.len > 0 and !std.mem.eql(u8, old_cat, cat_str)) {
            const old_cat_set = try RedisMemory.prefixedKey(self, "cat", old_cat);
            defer self.allocator.free(old_cat_set);
            var resp = try RedisMemory.sendCommand(self, &.{ "SREM", old_cat_set, storage_key });
            resp.deinit(self.allocator);
        }
    }

    if (old_sid_str) |old_sid| {
        const new_sid = session_id orelse "";
        if (old_sid.len > 0 and !std.mem.eql(u8, old_sid, new_sid)) {
            const old_sess_set = try RedisMemory.prefixedKey(self, "sessions", old_sid);
            defer self.allocator.free(old_sess_set);
            var resp = try RedisMemory.sendCommand(self, &.{ "SREM", old_sess_set, storage_key });
            resp.deinit(self.allocator);
        }
    }

    const sid = session_id orelse "";
    const value_kind_str = if (value_kind) |kind| kind.toString() else "";
    var ts_buf: [32]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{input.timestamp_ms}) catch unreachable;
    var seq_buf: [32]u8 = undefined;
    const seq_str = std.fmt.bufPrint(&seq_buf, "{d}", .{input.origin_sequence}) catch unreachable;
    var resp = try RedisMemory.sendCommand(self, &.{
        "HSET",                    entry_key,
        "id",                      id,
        "content",                 content,
        "category",                cat_str,
        "session_id",              sid,
        "created_at",              now,
        "updated_at",              now,
        "value_kind",              value_kind_str,
        "event_timestamp_ms",      ts_str,
        "event_origin_instance_id", input.origin_instance_id,
        "event_origin_sequence",   seq_str,
    });
    resp.deinit(self.allocator);

    const keys_set = try RedisMemory.prefixedSimple(self, "keys");
    defer self.allocator.free(keys_set);
    resp = try RedisMemory.sendCommand(self, &.{ "SADD", keys_set, storage_key });
    resp.deinit(self.allocator);

    const cat_set = try RedisMemory.prefixedKey(self, "cat", cat_str);
    defer self.allocator.free(cat_set);
    resp = try RedisMemory.sendCommand(self, &.{ "SADD", cat_set, storage_key });
    resp.deinit(self.allocator);

    if (session_id) |sid_val| {
        const sess_set = try RedisMemory.prefixedKey(self, "sessions", sid_val);
        defer self.allocator.free(sess_set);
        resp = try RedisMemory.sendCommand(self, &.{ "SADD", sess_set, storage_key });
        resp.deinit(self.allocator);
    }

    if (self.ttl_seconds) |ttl| {
        var ttl_buf: [12]u8 = undefined;
        const ttl_str = std.fmt.bufPrint(&ttl_buf, "{d}", .{ttl}) catch unreachable;
        resp = try RedisMemory.sendCommand(self, &.{ "EXPIRE", entry_key, ttl_str });
        resp.deinit(self.allocator);
    }
}

fn tombstoneBlocksPut(self: *RedisMemory, allocator: std.mem.Allocator, input: MemoryEventInput) !bool {
    const storage_key = try key_codec.encode(allocator, input.key, input.session_id);
    defer allocator.free(storage_key);

    if (try getTombstoneMeta(self, allocator, storage_key, true)) |meta| {
        defer meta.deinit(allocator);
        if (RedisMemory.compareInputToMetadata(input, meta.timestamp_ms, meta.origin_instance_id, meta.origin_sequence) <= 0) return true;
    }
    if (try getTombstoneMeta(self, allocator, input.key, false)) |meta| {
        defer meta.deinit(allocator);
        if (RedisMemory.compareInputToMetadata(input, meta.timestamp_ms, meta.origin_instance_id, meta.origin_sequence) <= 0) return true;
    }
    return false;
}

fn upsertTombstone(self: *RedisMemory, key: []const u8, scoped: bool, session_id: ?[]const u8, input: MemoryEventInput) !void {
    const tomb_key_name = if (scoped)
        try key_codec.encode(self.allocator, key, session_id)
    else
        try self.allocator.dupe(u8, key);
    defer self.allocator.free(tomb_key_name);

    if (try getTombstoneMeta(self, self.allocator, tomb_key_name, scoped)) |meta| {
        defer meta.deinit(self.allocator);
        if (RedisMemory.compareInputToMetadata(input, meta.timestamp_ms, meta.origin_instance_id, meta.origin_sequence) <= 0) return;
    }

    const tomb_key = if (scoped)
        try self.tombScopedKey(tomb_key_name)
    else
        try self.tombKeyKey(tomb_key_name);
    defer self.allocator.free(tomb_key);

    const index_key = if (scoped)
        try self.tombScopedIndexKey()
    else
        try self.tombKeyIndexKey();
    defer self.allocator.free(index_key);

    var ts_buf: [32]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{input.timestamp_ms}) catch unreachable;
    var seq_buf: [32]u8 = undefined;
    const seq_str = std.fmt.bufPrint(&seq_buf, "{d}", .{input.origin_sequence}) catch unreachable;
    const sid = session_id orelse "";
    var resp = try self.sendCommand(&.{
        "HSET",                    tomb_key,
        "key",                     key,
        "session_id",              sid,
        "timestamp_ms",            ts_str,
        "origin_instance_id",      input.origin_instance_id,
        "origin_sequence",         seq_str,
    });
    resp.deinit(self.allocator);
    resp = try self.sendCommand(&.{ "SADD", index_key, tomb_key_name });
    resp.deinit(self.allocator);
}

fn applyPutProjection(self: *RedisMemory, input: MemoryEventInput) !void {
    if (try tombstoneBlocksPut(self, self.allocator, input)) return;

    const storage_key = try key_codec.encode(self.allocator, input.key, input.session_id);
    defer self.allocator.free(storage_key);
    const existing = try getStoredRecordByStorageKey(self, self.allocator, storage_key);
    if (existing) |record| {
        defer {
            var mutable = record;
            mutable.deinit(self.allocator);
        }
        if (RedisMemory.compareInputToMetadata(input, record.event_timestamp_ms, record.event_origin_instance_id, record.event_origin_sequence) <= 0) return;
        const resolved = try root.resolveMemoryEventState(self.allocator, record.entry.content, record.entry.category, record.value_kind, input) orelse return error.InvalidEvent;
        defer resolved.deinit(self.allocator);
        try upsertProjection(self, input.key, resolved.content, resolved.category, resolved.value_kind, input.session_id, input);
        return;
    }

    const resolved = try root.resolveMemoryEventState(self.allocator, null, null, null, input) orelse return error.InvalidEvent;
    defer resolved.deinit(self.allocator);
    try upsertProjection(self, input.key, resolved.content, resolved.category, resolved.value_kind, input.session_id, input);
}

fn deleteScopedProjection(self: *RedisMemory, input: MemoryEventInput) !void {
    const storage_key = try key_codec.encode(self.allocator, input.key, input.session_id);
    defer self.allocator.free(storage_key);
    const existing = try getStoredRecordByStorageKey(self, self.allocator, storage_key);
    if (existing) |record| {
        defer {
            var mutable = record;
            mutable.deinit(self.allocator);
        }
        if (RedisMemory.compareInputToMetadata(input, record.event_timestamp_ms, record.event_origin_instance_id, record.event_origin_sequence) >= 0) {
            _ = try deleteStorageKey(self, storage_key);
        }
    }
}

fn deleteAllProjection(self: *RedisMemory, input: MemoryEventInput) !void {
    const keys_set = try self.prefixedSimple("keys");
    defer self.allocator.free(keys_set);
    var keys_resp = try self.sendCommandAlloc(self.allocator, &.{ "SMEMBERS", keys_set });
    defer keys_resp.deinit(self.allocator);
    const storage_keys = switch (keys_resp) {
        .array => |maybe_arr| maybe_arr orelse return,
        else => return,
    };

    for (storage_keys) |kv| {
        const storage_key = kv.asString() orelse continue;
        const decoded = key_codec.decode(storage_key);
        if (!std.mem.eql(u8, decoded.logical_key, input.key)) continue;
        const existing = try getStoredRecordByStorageKey(self, self.allocator, storage_key);
        if (existing) |record| {
            defer {
                var mutable = record;
                mutable.deinit(self.allocator);
            }
            if (RedisMemory.compareInputToMetadata(input, record.event_timestamp_ms, record.event_origin_instance_id, record.event_origin_sequence) >= 0) {
                _ = try deleteStorageKey(self, storage_key);
            }
        }
    }
}

fn appendNativeEvent(self: *RedisMemory, input: MemoryEventInput) !void {
    const local_sequence = try self.nextEventSequence();
    const stream_key = try self.feedEventsKey();
    defer self.allocator.free(stream_key);
    var id_buf: [32]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "{d}-0", .{local_sequence}) catch unreachable;
    var origin_seq_buf: [32]u8 = undefined;
    const origin_seq = std.fmt.bufPrint(&origin_seq_buf, "{d}", .{input.origin_sequence}) catch unreachable;
    var ts_buf: [32]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "{d}", .{input.timestamp_ms}) catch unreachable;
    const category = if (input.category) |value| value.toString() else "";
    const value_kind = if (input.value_kind) |value| value.toString() else "";
    const content = input.content orelse "";
    const session_id = input.session_id orelse "";

    var resp = try self.sendCommand(&.{
        "XADD",             stream_key, id,
        "schema_version",   "1",
        "origin_instance_id", input.origin_instance_id,
        "origin_sequence",  origin_seq,
        "timestamp_ms",     ts,
        "operation",        input.operation.toString(),
        "key",              input.key,
        "session_id",       session_id,
        "category",         category,
        "value_kind",       value_kind,
        "content",          content,
    });
    resp.deinit(self.allocator);
}

fn applyEventInternal(self: *RedisMemory, input: MemoryEventInput) !void {
    const frontier = try self.getFrontier(input.origin_instance_id);
    if (input.origin_sequence <= frontier) return;

    try appendNativeEvent(self, input);
    switch (input.operation) {
        .put, .merge_object, .merge_string_set => try applyPutProjection(self, input),
        .delete_scoped => {
            try deleteScopedProjection(self, input);
            try upsertTombstone(self, input.key, true, input.session_id, input);
        },
        .delete_all => {
            try deleteAllProjection(self, input);
            try upsertTombstone(self, input.key, false, null, input);
        },
    }
    try self.setFrontier(input.origin_instance_id, input.origin_sequence);
}

fn emitLocalEvent(self: *RedisMemory, operation: root.MemoryEventOp, key: []const u8, session_id: ?[]const u8, category: ?MemoryCategory, value_kind: ?MemoryValueKind, content: ?[]const u8) !void {
    try applyEventInternal(self, .{
        .origin_instance_id = self.localInstanceId(),
        .origin_sequence = try self.nextLocalOriginSequence(),
        .timestamp_ms = std.time.milliTimestamp(),
        .operation = operation,
        .key = key,
        .session_id = session_id,
        .category = category,
        .value_kind = value_kind,
        .content = content,
    });
}

fn deleteStorageKey(self: *RedisMemory, storage_key: []const u8) !bool {
    const entry_key = try RedisMemory.prefixedKey(self, "entry", storage_key);
    defer self.allocator.free(entry_key);

    var cat_resp = try RedisMemory.sendCommand(self, &.{ "HGET", entry_key, "category" });
    const cat_str = cat_resp.asString();
    defer cat_resp.deinit(self.allocator);

    var sid_resp = try RedisMemory.sendCommand(self, &.{ "HGET", entry_key, "session_id" });
    const sid_str = sid_resp.asString();
    defer sid_resp.deinit(self.allocator);

    var del_resp = try RedisMemory.sendCommand(self, &.{ "DEL", entry_key });
    const deleted = switch (del_resp) {
        .integer => |n| n > 0,
        else => false,
    };
    del_resp.deinit(self.allocator);
    if (!deleted) return false;

    const keys_set = try RedisMemory.prefixedSimple(self, "keys");
    defer self.allocator.free(keys_set);
    var srem_resp = try RedisMemory.sendCommand(self, &.{ "SREM", keys_set, storage_key });
    srem_resp.deinit(self.allocator);

    if (cat_str) |cat| {
        if (cat.len > 0) {
            const cat_set = try RedisMemory.prefixedKey(self, "cat", cat);
            defer self.allocator.free(cat_set);
            var cat_srem = try RedisMemory.sendCommand(self, &.{ "SREM", cat_set, storage_key });
            cat_srem.deinit(self.allocator);
        }
    }

    if (sid_str) |sid| {
        if (sid.len > 0) {
            const sess_set = try RedisMemory.prefixedKey(self, "sessions", sid);
            defer self.allocator.free(sess_set);
            var sess_srem = try RedisMemory.sendCommand(self, &.{ "SREM", sess_set, storage_key });
            sess_srem.deinit(self.allocator);
        }
    }

    return true;
}

fn clearRedisFeedAndProjection(self: *RedisMemory) !void {
    const keys_set = try self.prefixedSimple("keys");
    defer self.allocator.free(keys_set);

    var keys_resp = try self.sendCommandAlloc(self.allocator, &.{ "SMEMBERS", keys_set });
    defer keys_resp.deinit(self.allocator);
    const storage_keys = switch (keys_resp) {
        .array => |maybe_arr| maybe_arr orelse &.{},
        else => &.{},
    };
    for (storage_keys) |kv| {
        const storage_key = kv.asString() orelse continue;
        _ = try deleteStorageKey(self, storage_key);
    }

    const scoped_index = try self.tombScopedIndexKey();
    defer self.allocator.free(scoped_index);
    var scoped_resp = try self.sendCommandAlloc(self.allocator, &.{ "SMEMBERS", scoped_index });
    defer scoped_resp.deinit(self.allocator);
    const scoped_keys = switch (scoped_resp) {
        .array => |maybe_arr| maybe_arr orelse &.{},
        else => &.{},
    };
    for (scoped_keys) |kv| {
        const key = kv.asString() orelse continue;
        const tomb_key = try self.tombScopedKey(key);
        defer self.allocator.free(tomb_key);
        var del_resp = try self.sendCommand(&.{ "DEL", tomb_key });
        del_resp.deinit(self.allocator);
    }

    const key_index = try self.tombKeyIndexKey();
    defer self.allocator.free(key_index);
    var key_resp = try self.sendCommandAlloc(self.allocator, &.{ "SMEMBERS", key_index });
    defer key_resp.deinit(self.allocator);
    const key_keys = switch (key_resp) {
        .array => |maybe_arr| maybe_arr orelse &.{},
        else => &.{},
    };
    for (key_keys) |kv| {
        const key = kv.asString() orelse continue;
        const tomb_key = try self.tombKeyKey(key);
        defer self.allocator.free(tomb_key);
        var del_resp = try self.sendCommand(&.{ "DEL", tomb_key });
        del_resp.deinit(self.allocator);
    }

    const stream_key = try self.feedEventsKey();
    defer self.allocator.free(stream_key);
    const meta_key = try self.feedMetaKey();
    defer self.allocator.free(meta_key);
    const frontiers_key = try self.feedFrontiersKey();
    defer self.allocator.free(frontiers_key);

    var del_resp = try self.sendCommand(&.{ "DEL", stream_key, meta_key, frontiers_key, scoped_index, key_index, keys_set });
    del_resp.deinit(self.allocator);
}

// ── Tests ──────────────────────────────────────────────────────────

// RESP protocol tests (no Redis server needed)

test "formatCommand SET key value" {
    const cmd = try formatCommand(std.testing.allocator, &.{ "SET", "key", "value" });
    defer std.testing.allocator.free(cmd);
    try std.testing.expectEqualStrings("*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$5\r\nvalue\r\n", cmd);
}

test "formatCommand PING (no args)" {
    const cmd = try formatCommand(std.testing.allocator, &.{"PING"});
    defer std.testing.allocator.free(cmd);
    try std.testing.expectEqualStrings("*1\r\n$4\r\nPING\r\n", cmd);
}

test "formatCommand HSET multiple fields" {
    const cmd = try formatCommand(std.testing.allocator, &.{ "HSET", "myhash", "field1", "val1", "field2", "val2" });
    defer std.testing.allocator.free(cmd);
    try std.testing.expectEqualStrings("*6\r\n$4\r\nHSET\r\n$6\r\nmyhash\r\n$6\r\nfield1\r\n$4\r\nval1\r\n$6\r\nfield2\r\n$4\r\nval2\r\n", cmd);
}

test "formatCommand empty string arg" {
    const cmd = try formatCommand(std.testing.allocator, &.{ "SET", "key", "" });
    defer std.testing.allocator.free(cmd);
    try std.testing.expectEqualStrings("*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$0\r\n\r\n", cmd);
}

test "parseResp simple string" {
    const result = try parseResp(std.testing.allocator, "+OK\r\n");
    var val = result.value;
    defer val.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("OK", val.simple_string);
    try std.testing.expectEqual(@as(usize, 5), result.consumed);
}

test "parseResp error" {
    const result = try parseResp(std.testing.allocator, "-ERR unknown\r\n");
    var val = result.value;
    defer val.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ERR unknown", val.err);
    try std.testing.expectEqual(@as(usize, 14), result.consumed);
}

test "parseResp integer" {
    const result = try parseResp(std.testing.allocator, ":42\r\n");
    var val = result.value;
    defer val.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 42), val.integer);
    try std.testing.expectEqual(@as(usize, 5), result.consumed);
}

test "parseResp negative integer" {
    const result = try parseResp(std.testing.allocator, ":-1\r\n");
    var val = result.value;
    defer val.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, -1), val.integer);
}

test "parseResp bulk string" {
    const result = try parseResp(std.testing.allocator, "$5\r\nhello\r\n");
    var val = result.value;
    defer val.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", val.bulk_string.?);
    try std.testing.expectEqual(@as(usize, 11), result.consumed);
}

test "parseResp null bulk string" {
    const result = try parseResp(std.testing.allocator, "$-1\r\n");
    var val = result.value;
    defer val.deinit(std.testing.allocator);
    try std.testing.expect(val.bulk_string == null);
    try std.testing.expectEqual(@as(usize, 5), result.consumed);
}

test "parseResp empty bulk string" {
    const result = try parseResp(std.testing.allocator, "$0\r\n\r\n");
    var val = result.value;
    defer val.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", val.bulk_string.?);
}

test "parseResp array" {
    const data = "*2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n";
    const result = try parseResp(std.testing.allocator, data);
    var val = result.value;
    defer val.deinit(std.testing.allocator);
    const arr = val.array.?;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("foo", arr[0].bulk_string.?);
    try std.testing.expectEqualStrings("bar", arr[1].bulk_string.?);
}

test "parseResp null array" {
    const result = try parseResp(std.testing.allocator, "*-1\r\n");
    var val = result.value;
    defer val.deinit(std.testing.allocator);
    try std.testing.expect(val.array == null);
}

test "parseResp empty array" {
    const result = try parseResp(std.testing.allocator, "*0\r\n");
    var val = result.value;
    defer val.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), val.array.?.len);
}

test "parseResp nested array" {
    const data = "*2\r\n*2\r\n:1\r\n:2\r\n*1\r\n+OK\r\n";
    const result = try parseResp(std.testing.allocator, data);
    var val = result.value;
    defer val.deinit(std.testing.allocator);
    const arr = val.array.?;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    const inner1 = arr[0].array.?;
    try std.testing.expectEqual(@as(i64, 1), inner1[0].integer);
    try std.testing.expectEqual(@as(i64, 2), inner1[1].integer);
    const inner2 = arr[1].array.?;
    try std.testing.expectEqualStrings("OK", inner2[0].simple_string);
}

test "parseResp incomplete data returns error" {
    try std.testing.expectError(error.IncompleteData, parseResp(std.testing.allocator, "+OK\r"));
    try std.testing.expectError(error.IncompleteData, parseResp(std.testing.allocator, "$5\r\nhel"));
    try std.testing.expectError(error.IncompleteData, parseResp(std.testing.allocator, ""));
}

test "parseResp unknown type returns error" {
    try std.testing.expectError(error.UnknownRespType, parseResp(std.testing.allocator, "?invalid\r\n"));
}

test "parseResp mixed array" {
    const data = "*3\r\n:1\r\n$5\r\nhello\r\n+OK\r\n";
    const result = try parseResp(std.testing.allocator, data);
    var val = result.value;
    defer val.deinit(std.testing.allocator);
    const arr = val.array.?;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqual(@as(i64, 1), arr[0].integer);
    try std.testing.expectEqualStrings("hello", arr[1].bulk_string.?);
    try std.testing.expectEqualStrings("OK", arr[2].simple_string);
}

test "parseHashFields basic" {
    // Simulate HGETALL response fields: [field, value, field, value, ...]
    var fields = [_]RespValue{
        .{ .bulk_string = "id" },
        .{ .bulk_string = "test-id-123" },
        .{ .bulk_string = "content" },
        .{ .bulk_string = "hello world" },
        .{ .bulk_string = "category" },
        .{ .bulk_string = "core" },
        .{ .bulk_string = "session_id" },
        .{ .bulk_string = "" },
        .{ .bulk_string = "updated_at" },
        .{ .bulk_string = "1700000000" },
    };

    var entry = try parseHashFields(std.testing.allocator, "test-key", &fields);
    defer entry.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("test-id-123", entry.id);
    try std.testing.expectEqualStrings("test-key", entry.key);
    try std.testing.expectEqualStrings("hello world", entry.content);
    try std.testing.expect(entry.category.eql(.core));
    try std.testing.expectEqualStrings("1700000000", entry.timestamp);
    try std.testing.expect(entry.session_id == null); // empty string → null
}

test "parseHashFields with session_id" {
    var fields = [_]RespValue{
        .{ .bulk_string = "id" },
        .{ .bulk_string = "id-1" },
        .{ .bulk_string = "content" },
        .{ .bulk_string = "data" },
        .{ .bulk_string = "category" },
        .{ .bulk_string = "daily" },
        .{ .bulk_string = "session_id" },
        .{ .bulk_string = "sess-42" },
        .{ .bulk_string = "updated_at" },
        .{ .bulk_string = "12345" },
    };

    var entry = try parseHashFields(std.testing.allocator, "k", &fields);
    defer entry.deinit(std.testing.allocator);

    try std.testing.expect(entry.category.eql(.daily));
    try std.testing.expectEqualStrings("sess-42", entry.session_id.?);
}

test "parseHashFields custom category" {
    var fields = [_]RespValue{
        .{ .bulk_string = "id" },
        .{ .bulk_string = "id-1" },
        .{ .bulk_string = "content" },
        .{ .bulk_string = "stuff" },
        .{ .bulk_string = "category" },
        .{ .bulk_string = "my_custom" },
        .{ .bulk_string = "session_id" },
        .{ .bulk_string = "" },
        .{ .bulk_string = "updated_at" },
        .{ .bulk_string = "99" },
    };

    var entry = try parseHashFields(std.testing.allocator, "k", &fields);
    defer entry.deinit(std.testing.allocator);

    switch (entry.category) {
        .custom => |name| try std.testing.expectEqualStrings("my_custom", name),
        else => return error.TestUnexpectedResult,
    }
}

test "RespValue deinit frees all memory" {
    // This test verifies no leaks via the testing allocator
    var val = RespValue{ .simple_string = try std.testing.allocator.dupe(u8, "hello") };
    val.deinit(std.testing.allocator);

    var arr_items = try std.testing.allocator.alloc(RespValue, 2);
    arr_items[0] = .{ .bulk_string = try std.testing.allocator.dupe(u8, "a") };
    arr_items[1] = .{ .integer = 42 };
    var val2 = RespValue{ .array = arr_items };
    val2.deinit(std.testing.allocator);
}

test "formatCommand roundtrip with parseResp" {
    // Format a command and verify it starts with the right array header
    const cmd = try formatCommand(std.testing.allocator, &.{ "GET", "mykey" });
    defer std.testing.allocator.free(cmd);

    // Parse the command we just formatted (it's valid RESP)
    const result = try parseResp(std.testing.allocator, cmd);
    var val = result.value;
    defer val.deinit(std.testing.allocator);

    const arr = val.array.?;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("GET", arr[0].bulk_string.?);
    try std.testing.expectEqualStrings("mykey", arr[1].bulk_string.?);
}

test "normalizeInstanceId maps empty id to default" {
    try std.testing.expectEqualStrings("default", normalizeInstanceId(""));
    try std.testing.expectEqualStrings("agent-a", normalizeInstanceId("agent-a"));
}

test "redis prefixes always include normalized instance id" {
    var mem = RedisMemory{
        .allocator = std.testing.allocator,
        .host = "127.0.0.1",
        .port = 6379,
        .password = null,
        .db_index = 0,
        .key_prefix = "nullclaw",
        .ttl_seconds = null,
        .instance_id = normalizeInstanceId(""),
    };

    const simple = try mem.prefixedSimple("keys");
    defer std.testing.allocator.free(simple);
    try std.testing.expectEqualStrings("nullclaw:default:keys", simple);

    const full = try mem.prefixedKey("entry", "prefs/theme|null");
    defer std.testing.allocator.free(full);
    try std.testing.expectEqualStrings("nullclaw:default:entry:prefs/theme|null", full);
}

// Integration tests — guarded by Redis availability
fn canConnectToRedis() bool {
    const addr = std.net.Address.resolveIp("127.0.0.1", 6379) catch return false;
    const stream = std.net.tcpConnectToAddress(addr) catch return false;
    stream.close();
    return true;
}

test "integration: redis store and get" {
    if (!canConnectToRedis()) return;

    var mem = try RedisMemory.init(std.testing.allocator, .{
        .key_prefix = "nullclaw_test",
    });
    defer mem.deinit();

    const m = mem.memory();

    // Clean up first
    _ = try m.forget("test-integration-key");

    try m.store("test-integration-key", "hello redis", .core, null);

    const entry = try m.get(std.testing.allocator, "test-integration-key") orelse
        return error.TestUnexpectedResult;
    defer entry.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("test-integration-key", entry.key);
    try std.testing.expectEqualStrings("hello redis", entry.content);
    try std.testing.expect(entry.category.eql(.core));

    // Cleanup
    _ = try m.forget("test-integration-key");
}

test "integration: redis count" {
    if (!canConnectToRedis()) return;

    var mem = try RedisMemory.init(std.testing.allocator, .{
        .key_prefix = "nullclaw_test_count",
    });
    defer mem.deinit();

    const m = mem.memory();

    // Store two entries
    try m.store("count-a", "aaa", .core, null);
    try m.store("count-b", "bbb", .daily, null);

    const n = try m.count();
    try std.testing.expect(n >= 2);

    // Cleanup
    _ = try m.forget("count-a");
    _ = try m.forget("count-b");
}

test "integration: redis recall substring" {
    if (!canConnectToRedis()) return;

    var mem = try RedisMemory.init(std.testing.allocator, .{
        .key_prefix = "nullclaw_test_recall",
    });
    defer mem.deinit();

    const m = mem.memory();

    try m.store("recall-1", "the quick brown fox", .core, null);
    try m.store("recall-2", "lazy dog sleeps", .core, null);

    const results = try m.recall(std.testing.allocator, "brown fox", 10, null);
    defer root.freeEntries(std.testing.allocator, results);

    try std.testing.expect(results.len >= 1);
    try std.testing.expectEqualStrings("the quick brown fox", results[0].content);

    // Cleanup
    _ = try m.forget("recall-1");
    _ = try m.forget("recall-2");
}

test "integration: redis forget" {
    if (!canConnectToRedis()) return;

    var mem = try RedisMemory.init(std.testing.allocator, .{
        .key_prefix = "nullclaw_test_forget",
    });
    defer mem.deinit();

    const m = mem.memory();

    try m.store("forget-me", "temp data", .conversation, null);
    const ok = try m.forget("forget-me");
    try std.testing.expect(ok);

    const entry = try m.get(std.testing.allocator, "forget-me");
    try std.testing.expect(entry == null);
}

test "integration: redis native feed roundtrip" {
    if (!canConnectToRedis()) return;

    var first = try RedisMemory.init(std.testing.allocator, .{
        .key_prefix = "nullclaw_test_feed_roundtrip",
        .instance_id = "agent-a",
    });
    defer first.deinit();
    try clearRedisFeedAndProjection(&first);

    var second = try RedisMemory.init(std.testing.allocator, .{
        .key_prefix = "nullclaw_test_feed_roundtrip",
        .instance_id = "agent-b",
    });
    defer second.deinit();
    try clearRedisFeedAndProjection(&second);

    const first_mem = first.memory();
    const second_mem = second.memory();

    try first_mem.store("prefs/theme", "solarized", .core, "sess-a");

    var info = try first_mem.eventFeedInfo(std.testing.allocator);
    defer info.deinit(std.testing.allocator);
    try std.testing.expectEqual(root.MemoryEventFeedStorage.native, info.storage_kind);
    try std.testing.expectEqual(@as(u64, 1), info.last_sequence);

    const events = try first_mem.listEvents(std.testing.allocator, 0, 10);
    defer root.freeEvents(std.testing.allocator, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(root.MemoryEventOp.put, events[0].operation);

    try second_mem.applyEvent(.{
        .origin_instance_id = events[0].origin_instance_id,
        .origin_sequence = events[0].origin_sequence,
        .timestamp_ms = events[0].timestamp_ms,
        .operation = events[0].operation,
        .key = events[0].key,
        .session_id = events[0].session_id,
        .category = events[0].category,
        .value_kind = events[0].value_kind,
        .content = events[0].content,
    });

    const restored = try second_mem.getScoped(std.testing.allocator, "prefs/theme", "sess-a") orelse
        return error.TestUnexpectedResult;
    defer restored.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("solarized", restored.content);
}

test "integration: redis feed compact and checkpoint restore" {
    if (!canConnectToRedis()) return;

    var source = try RedisMemory.init(std.testing.allocator, .{
        .key_prefix = "nullclaw_test_feed_checkpoint",
        .instance_id = "agent-a",
    });
    defer source.deinit();
    try clearRedisFeedAndProjection(&source);

    const source_mem = source.memory();
    try source_mem.store("prefs/language", "zig", .core, null);
    try source_mem.store("prefs/editor", "zed", .core, "sess-b");

    const checkpoint = try source_mem.exportCheckpoint(std.testing.allocator);
    defer std.testing.allocator.free(checkpoint);

    const compacted = try source_mem.compactEvents();
    try std.testing.expect(compacted >= 2);
    try std.testing.expectError(error.CursorExpired, source_mem.listEvents(std.testing.allocator, 0, 10));

    var restored = try RedisMemory.init(std.testing.allocator, .{
        .key_prefix = "nullclaw_test_feed_checkpoint",
        .instance_id = "agent-b",
    });
    defer restored.deinit();
    try clearRedisFeedAndProjection(&restored);

    const restored_mem = restored.memory();
    try restored_mem.applyCheckpoint(checkpoint);

    const global_entry = try restored_mem.get(std.testing.allocator, "prefs/language") orelse
        return error.TestUnexpectedResult;
    defer global_entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zig", global_entry.content);

    const scoped_entry = try restored_mem.getScoped(std.testing.allocator, "prefs/editor", "sess-b") orelse
        return error.TestUnexpectedResult;
    defer scoped_entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zed", scoped_entry.content);

    var restored_info = try restored_mem.eventFeedInfo(std.testing.allocator);
    defer restored_info.deinit(std.testing.allocator);
    try std.testing.expect(restored_info.next_local_origin_sequence >= 2);
    try std.testing.expect(restored_info.last_sequence >= 2);
}

test "integration: redis health check" {
    if (!canConnectToRedis()) return;

    var mem = try RedisMemory.init(std.testing.allocator, .{
        .key_prefix = "nullclaw_test_health",
    });
    defer mem.deinit();

    try std.testing.expect(mem.memory().healthCheck());
}

test "integration: redis name" {
    if (!canConnectToRedis()) return;

    var mem = try RedisMemory.init(std.testing.allocator, .{});
    defer mem.deinit();

    try std.testing.expectEqualStrings("redis", mem.memory().name());
}
