//! ClickHouse-backed persistent memory via HTTP API (port 8123).
//!
//! No C dependency — pure Zig HTTP via std.http.Client.
//! Writes are append-only with server-generated Snowflake ordering keys, and
//! reads collapse to the latest row per logical key+session via argMax. This keeps
//! ordering independent from client clock skew while ReplacingMergeTree(version)
//! provides eventual on-disk compaction. User data is parameterized via
//! ClickHouse query parameters ({name:Type} syntax).

const std = @import("std");
const build_options = @import("build_options");
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
const SessionStore = root.SessionStore;
const MessageEntry = root.MessageEntry;
const ResolvedMemoryState = root.ResolvedMemoryState;
const log = std.log.scoped(.clickhouse_memory);

// ── SQL injection protection ──────────────────────────────────────

pub const IdentifierError = error{
    EmptyIdentifier,
    IdentifierTooLong,
    InvalidCharacter,
};

/// Validate a SQL identifier (database/table name).
/// Must be 1-63 chars, alphanumeric or underscore only.
pub fn validateIdentifier(name: []const u8) IdentifierError!void {
    if (name.len == 0) return error.EmptyIdentifier;
    if (name.len > 63) return error.IdentifierTooLong;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') {
            return error.InvalidCharacter;
        }
    }
}

/// Quote a SQL identifier by wrapping in backticks (ClickHouse syntax).
pub fn quoteIdentifier(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "`{s}`", .{name});
}

/// Escape a string for safe inclusion in ClickHouse string literals.
/// Escapes ', \, \n, \r, \t, and \0.
pub fn escapeClickHouseString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (input) |ch| {
        switch (ch) {
            '\'' => try buf.appendSlice(allocator, "\\'"),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0 => try buf.appendSlice(allocator, "\\0"),
            else => try buf.append(allocator, ch),
        }
    }

    return buf.toOwnedSlice(allocator);
}

/// Build the ClickHouse HTTP API base URL from host, port, and TLS setting.
pub fn buildUrl(allocator: std.mem.Allocator, host: []const u8, port: u16, use_https: bool) ![]u8 {
    const scheme = if (use_https) "https" else "http";
    const needs_brackets = std.mem.indexOfScalar(u8, host, ':') != null and
        !(host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']');
    const host_part = if (needs_brackets)
        try std.fmt.allocPrint(allocator, "[{s}]", .{host})
    else
        try allocator.dupe(u8, host);
    defer allocator.free(host_part);
    return std.fmt.allocPrint(allocator, "{s}://{s}:{d}", .{ scheme, host_part, port });
}

/// Build a Basic auth header value ("Basic base64(user:password)").
/// Returns null if both user and password are empty.
pub fn buildAuthHeader(allocator: std.mem.Allocator, user: []const u8, password: []const u8) !?[]u8 {
    if (user.len == 0 and password.len == 0) return null;

    const credentials = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ user, password });
    defer allocator.free(credentials);

    const Encoder = std.base64.standard.Encoder;
    const encoded_len = Encoder.calcSize(credentials.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = Encoder.encode(encoded, credentials);

    const header = try std.fmt.allocPrint(allocator, "Basic {s}", .{encoded});
    return header;
}

/// Percent-encode a string for use in URL query parameters.
/// Safe characters (unreserved per RFC 3986) are not encoded.
pub fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (input) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try buf.append(allocator, ch);
        } else {
            const hex = "0123456789ABCDEF";
            try buf.append(allocator, '%');
            try buf.append(allocator, hex[ch >> 4]);
            try buf.append(allocator, hex[ch & 0x0f]);
        }
    }

    return buf.toOwnedSlice(allocator);
}

// ── Timestamp / ID helpers ────────────────────────────────────────

fn getNowTimestamp(allocator: std.mem.Allocator) ![]u8 {
    const ts = std.time.timestamp();
    return std.fmt.allocPrint(allocator, "{d}", .{ts});
}

fn generateId(allocator: std.mem.Allocator) ![]u8 {
    const ts = std.time.nanoTimestamp();
    var buf: [16]u8 = undefined;
    std.crypto.random.bytes(&buf);
    const rand_hi = std.mem.readInt(u64, buf[0..8], .little);
    const rand_lo = std.mem.readInt(u64, buf[8..16], .little);
    return std.fmt.allocPrint(allocator, "{d}-{x}-{x}", .{ ts, rand_hi, rand_lo });
}

fn normalizeInstanceId(instance_id: []const u8) []const u8 {
    return if (instance_id.len > 0) instance_id else "default";
}

fn parseCategoryOwned(allocator: std.mem.Allocator, text: []const u8) !MemoryCategory {
    const parsed = MemoryCategory.fromString(text);
    return switch (parsed) {
        .custom => .{ .custom = try allocator.dupe(u8, text) },
        else => parsed,
    };
}

fn parseValueKind(text: []const u8) !?MemoryValueKind {
    if (text.len == 0) return null;
    return MemoryValueKind.fromString(text) orelse error.InvalidEvent;
}

fn compareInputToMetadata(input: MemoryEventInput, timestamp_ms: i64, origin_instance_id: []const u8, origin_sequence: u64) i8 {
    if (input.timestamp_ms < timestamp_ms) return -1;
    if (input.timestamp_ms > timestamp_ms) return 1;

    switch (std.mem.order(u8, input.origin_instance_id, origin_instance_id)) {
        .lt => return -1,
        .gt => return 1,
        .eq => {},
    }

    if (input.origin_sequence < origin_sequence) return -1;
    if (input.origin_sequence > origin_sequence) return 1;
    return 0;
}

// ── TSV parsing helpers ───────────────────────────────────────────

/// Unescape a ClickHouse TabSeparated field value.
/// Handles \n, \r, \t, \\, \0, \'.
pub fn unescapeClickHouseValue(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (i + 1 < input.len and input[i] == '\\') {
            switch (input[i + 1]) {
                'n' => try buf.append(allocator, '\n'),
                'r' => try buf.append(allocator, '\r'),
                't' => try buf.append(allocator, '\t'),
                '\\' => try buf.append(allocator, '\\'),
                '0' => try buf.append(allocator, 0),
                '\'' => try buf.append(allocator, '\''),
                else => {
                    try buf.append(allocator, input[i]);
                    try buf.append(allocator, input[i + 1]);
                },
            }
            i += 2;
        } else {
            try buf.append(allocator, input[i]);
            i += 1;
        }
    }

    return buf.toOwnedSlice(allocator);
}

/// Parse ClickHouse TabSeparated output into rows of columns.
/// Each row is a slice of column values (unescaped).
pub fn parseTsvRows(allocator: std.mem.Allocator, body: []const u8) ![]const []const []const u8 {
    if (body.len == 0) return allocator.alloc([]const []const u8, 0);

    var rows: std.ArrayList([]const []const u8) = .empty;
    errdefer {
        for (rows.items) |row| {
            for (row) |col| allocator.free(@constCast(col));
            allocator.free(row);
        }
        rows.deinit(allocator);
    }

    var line_iter = std.mem.splitScalar(u8, body, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;

        var cols: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (cols.items) |col| allocator.free(@constCast(col));
            cols.deinit(allocator);
        }

        var col_iter = std.mem.splitScalar(u8, line, '\t');
        while (col_iter.next()) |raw_col| {
            const unescaped = try unescapeClickHouseValue(allocator, raw_col);
            try cols.append(allocator, unescaped);
        }

        const row = try cols.toOwnedSlice(allocator);
        try rows.append(allocator, row);
    }

    return rows.toOwnedSlice(allocator);
}

/// Free rows returned by parseTsvRows.
pub fn freeTsvRows(allocator: std.mem.Allocator, rows: []const []const []const u8) void {
    for (rows) |row| {
        for (row) |col| allocator.free(@constCast(col));
        allocator.free(row);
    }
    allocator.free(rows);
}

/// Build a MemoryEntry from a TSV row.
/// Expected columns: [id, key, content, category, timestamp, session_id]
fn buildEntry(allocator: std.mem.Allocator, row: []const []const u8) !MemoryEntry {
    if (row.len < 6) return error.InvalidRow;

    const id = try allocator.dupe(u8, row[0]);
    errdefer allocator.free(id);
    const key = try allocator.dupe(u8, row[1]);
    errdefer allocator.free(key);
    const content = try allocator.dupe(u8, row[2]);
    errdefer allocator.free(content);
    const timestamp = try allocator.dupe(u8, row[4]);
    errdefer allocator.free(timestamp);

    const cat_str = row[3];
    const category = MemoryCategory.fromString(cat_str);
    const final_category: MemoryCategory = switch (category) {
        .custom => .{ .custom = try allocator.dupe(u8, cat_str) },
        else => category,
    };
    errdefer switch (final_category) {
        .custom => |name| allocator.free(name),
        else => {},
    };

    const sid_raw = row[5];
    const session_id: ?[]const u8 = if (sid_raw.len > 0) try allocator.dupe(u8, sid_raw) else null;

    return .{
        .id = id,
        .key = key,
        .content = content,
        .category = final_category,
        .timestamp = timestamp,
        .session_id = session_id,
    };
}

fn isLoopbackHost(host: []const u8) bool {
    const normalized = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']')
        host[1 .. host.len - 1]
    else
        host;

    if (std.ascii.eqlIgnoreCase(normalized, "localhost")) return true;

    if (std.net.Address.parseIp4(normalized, 0)) |ip4| {
        const octets: *const [4]u8 = @ptrCast(&ip4.in.sa.addr);
        return octets[0] == 127;
    } else |_| {}

    if (std.net.Address.parseIp6(normalized, 0)) |ip6| {
        const bytes = ip6.in6.sa.addr;
        return std.mem.eql(u8, bytes[0..15], &[_]u8{0} ** 15) and bytes[15] == 1;
    } else |_| {}

    return false;
}

    fn validateTransportSecurity(host: []const u8, use_https: bool) !void {
        if (use_https or isLoopbackHost(host)) return;
        return error.InsecureTransportNotAllowed;
    }

    fn memorySortingKeySupportsSessions(sorting_key: []const u8) bool {
        var normalized: std.ArrayListUnmanaged(u8) = .empty;
        defer normalized.deinit(std.heap.page_allocator);

        for (sorting_key) |ch| {
            switch (ch) {
                ' ', '\t', '\r', '\n', '`', '"', '(', ')' => {},
                else => normalized.append(std.heap.page_allocator, ch) catch return false,
            }
        }

        return std.mem.indexOf(u8, normalized.items, "instance_id,key,session_id") != null;
    }

// ── ClickHouseMemory ──────────────────────────────────────────────

pub const ClickHouseMemory = if (build_options.enable_memory_clickhouse) ClickHouseMemoryImpl else struct {};

const ClickHouseMemoryImpl = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    database: []const u8,
    table: []const u8,
    db_q: []const u8,
    table_q: []const u8,
    messages_table_q: []const u8,
    usage_table_q: []const u8,
    events_table_q: []const u8,
    frontiers_table_q: []const u8,
    tombstones_table_q: []const u8,
    feed_meta_table_q: []const u8,
    instance_id: []const u8,
    auth_header: ?[]const u8,
    owns_self: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: struct {
        host: []const u8 = "127.0.0.1",
        port: u16 = 8123,
        database: []const u8 = "default",
        table: []const u8 = "memories",
        user: []const u8 = "",
        password: []const u8 = "",
        use_https: bool = false,
        instance_id: []const u8 = "",
    }) !Self {
        try validateIdentifier(config.database);
        try validateIdentifier(config.table);
        try validateTransportSecurity(config.host, config.use_https);

        const base_url = try buildUrl(allocator, config.host, config.port, config.use_https);
        errdefer allocator.free(base_url);

        const db_q = try quoteIdentifier(allocator, config.database);
        errdefer allocator.free(db_q);
        const table_q = try quoteIdentifier(allocator, config.table);
        errdefer allocator.free(table_q);
        const messages_table_q = try buildQuotedSuffixTable(allocator, config.table, "_messages");
        errdefer allocator.free(messages_table_q);
        const usage_table_q = try buildQuotedSuffixTable(allocator, config.table, "_session_usage");
        errdefer allocator.free(usage_table_q);
        const events_table_q = try buildQuotedSuffixTable(allocator, config.table, "_events");
        errdefer allocator.free(events_table_q);
        const frontiers_table_q = try buildQuotedSuffixTable(allocator, config.table, "_event_frontiers");
        errdefer allocator.free(frontiers_table_q);
        const tombstones_table_q = try buildQuotedSuffixTable(allocator, config.table, "_tombstones");
        errdefer allocator.free(tombstones_table_q);
        const feed_meta_table_q = try buildQuotedSuffixTable(allocator, config.table, "_feed_meta");
        errdefer allocator.free(feed_meta_table_q);

        const auth_header = try buildAuthHeader(allocator, config.user, config.password);
        errdefer if (auth_header) |h| allocator.free(h);

        var self_ = Self{
            .allocator = allocator,
            .base_url = base_url,
            .database = config.database,
            .table = config.table,
            .db_q = db_q,
            .table_q = table_q,
            .messages_table_q = messages_table_q,
            .usage_table_q = usage_table_q,
            .events_table_q = events_table_q,
            .frontiers_table_q = frontiers_table_q,
            .tombstones_table_q = tombstones_table_q,
            .feed_meta_table_q = feed_meta_table_q,
            .instance_id = normalizeInstanceId(config.instance_id),
            .auth_header = auth_header,
        };

        try self_.ensureServerCapabilities();
        try self_.migrate();
        try self_.ensureScopedMemorySchema();
        try self_.bootstrapFeedFromExistingState();
        try self_.ensureProjectionUpToDate();

        return self_;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.base_url);
        self.allocator.free(self.db_q);
        self.allocator.free(self.table_q);
        self.allocator.free(self.messages_table_q);
        self.allocator.free(self.usage_table_q);
        self.allocator.free(self.events_table_q);
        self.allocator.free(self.frontiers_table_q);
        self.allocator.free(self.tombstones_table_q);
        self.allocator.free(self.feed_meta_table_q);
        if (self.auth_header) |h| self.allocator.free(h);
        if (self.owns_self) {
            self.allocator.destroy(self);
        }
    }

    // ── HTTP execution ────────────────────────────────────────────

    /// POST a query to ClickHouse HTTP API. Returns the response body.
    /// params is a slice of {name, value} pairs for query parameters.
    fn executeQuery(self: *Self, allocator: std.mem.Allocator, query: []const u8, params: []const [2][]const u8) ![]u8 {
        // Build URL with query parameters
        var url_buf: std.ArrayList(u8) = .empty;
        errdefer url_buf.deinit(allocator);

        try url_buf.appendSlice(allocator, self.base_url);
        try url_buf.appendSlice(allocator, "/?");

        for (params, 0..) |param, i| {
            if (i > 0) try url_buf.append(allocator, '&');
            const encoded_name = try urlEncode(allocator, param[0]);
            defer allocator.free(encoded_name);
            const encoded_value = try urlEncode(allocator, param[1]);
            defer allocator.free(encoded_value);
            try url_buf.appendSlice(allocator, "param_");
            try url_buf.appendSlice(allocator, encoded_name);
            try url_buf.append(allocator, '=');
            try url_buf.appendSlice(allocator, encoded_value);
        }

        const url = try url_buf.toOwnedSlice(allocator);
        defer allocator.free(url);

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var extra_headers_buf: [2]std.http.Header = undefined;
        var header_count: usize = 0;

        extra_headers_buf[header_count] = .{ .name = "Content-Type", .value = "text/plain" };
        header_count += 1;

        if (self.auth_header) |auth| {
            extra_headers_buf[header_count] = .{ .name = "Authorization", .value = auth };
            header_count += 1;
        }

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = query,
            .extra_headers = extra_headers_buf[0..header_count],
            .response_writer = &aw.writer,
        }) catch return error.ClickHouseConnectionError;

        if (result.status != .ok) {
            const err_body = aw.writer.buffer[0..aw.writer.end];
            log.err("ClickHouse error (HTTP {d}): {s}", .{ @intFromEnum(result.status), err_body });
            return error.ClickHouseQueryError;
        }

        const body = try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
        return body;
    }

    /// Execute a query that returns no meaningful body (DDL, INSERT).
    fn executeStatement(self: *Self, query: []const u8, params: []const [2][]const u8) !void {
        const body = try self.executeQuery(self.allocator, query, params);
        self.allocator.free(body);
    }

    /// Execute a mutation (ALTER TABLE DELETE) with mutations_sync=1.
    fn executeMutation(self: *Self, query: []const u8, params: []const [2][]const u8) !void {
        // Build URL with mutations_sync=1 plus query parameters
        var url_buf: std.ArrayList(u8) = .empty;
        errdefer url_buf.deinit(self.allocator);

        try url_buf.appendSlice(self.allocator, self.base_url);
        try url_buf.appendSlice(self.allocator, "/?mutations_sync=1");

        for (params) |param| {
            try url_buf.append(self.allocator, '&');
            const encoded_name = try urlEncode(self.allocator, param[0]);
            defer self.allocator.free(encoded_name);
            const encoded_value = try urlEncode(self.allocator, param[1]);
            defer self.allocator.free(encoded_value);
            try url_buf.appendSlice(self.allocator, "param_");
            try url_buf.appendSlice(self.allocator, encoded_name);
            try url_buf.append(self.allocator, '=');
            try url_buf.appendSlice(self.allocator, encoded_value);
        }

        const url = try url_buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(url);

        var client: std.http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        var extra_headers_buf: [2]std.http.Header = undefined;
        var header_count: usize = 0;

        extra_headers_buf[header_count] = .{ .name = "Content-Type", .value = "text/plain" };
        header_count += 1;

        if (self.auth_header) |auth| {
            extra_headers_buf[header_count] = .{ .name = "Authorization", .value = auth };
            header_count += 1;
        }

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = query,
            .extra_headers = extra_headers_buf[0..header_count],
            .response_writer = &aw.writer,
        }) catch return error.ClickHouseConnectionError;

        if (result.status != .ok) {
            const err_body = aw.writer.buffer[0..aw.writer.end];
            log.err("ClickHouse mutation error (HTTP {d}): {s}", .{ @intFromEnum(result.status), err_body });
            return error.ClickHouseQueryError;
        }
    }

    // ── Schema migration ──────────────────────────────────────────

    fn ensureServerCapabilities(self: *Self) !void {
        const body = self.executeQuery(self.allocator, "SELECT generateSnowflakeID()", &.{}) catch |err| switch (err) {
            error.ClickHouseQueryError => {
                log.err("ClickHouse backend requires generateSnowflakeID() support (ClickHouse 24.6+)", .{});
                return error.ClickHouseUnsupportedVersion;
            },
            else => return err,
        };
        self.allocator.free(body);
    }

    fn ensureScopedMemorySchema(self: *Self) !void {
        const body = try self.executeQuery(self.allocator,
            \\SELECT sorting_key
            \\FROM system.tables
            \\WHERE database = {{db:String}} AND name = {{table:String}}
            \\LIMIT 1
        , &.{
            .{ "db", self.database },
            .{ "table", self.table },
        });
        defer self.allocator.free(body);

        const sorting_key = std.mem.trim(u8, body, " \t\r\n");
        if (sorting_key.len == 0 or !memorySortingKeySupportsSessions(sorting_key)) {
            log.err("ClickHouse memory table {s}.{s} must use ORDER BY (instance_id, key, session_id); found sorting_key={s}", .{
                self.database,
                self.table,
                if (sorting_key.len > 0) sorting_key else "(empty)",
            });
            return error.ClickHouseInvalidSchema;
        }
    }

    fn migrate(self: *Self) !void {
        // 1. Main memories table (ReplacingMergeTree)
        const create_memories = try std.fmt.allocPrint(self.allocator,
            \\CREATE TABLE IF NOT EXISTS {s}.{s} (
            \\    id String,
            \\    key String,
            \\    content String,
            \\    category String DEFAULT '',
            \\    value_kind String DEFAULT '',
            \\    session_id String DEFAULT '',
            \\    instance_id String DEFAULT 'default',
            \\    event_timestamp_ms Int64 DEFAULT 0,
            \\    event_origin_instance_id String DEFAULT 'default',
            \\    event_origin_sequence UInt64 DEFAULT 0,
            \\    created_at DateTime64(3) DEFAULT now64(3),
            \\    updated_at DateTime64(3) DEFAULT now64(3),
            \\    version UInt64 DEFAULT generateSnowflakeID()
            \\) ENGINE = ReplacingMergeTree(version)
            \\ORDER BY (instance_id, key, session_id)
        , .{ self.db_q, self.table_q });
        defer self.allocator.free(create_memories);
        try self.executeStatement(create_memories, &.{});

        const alter_memories_version = try std.fmt.allocPrint(self.allocator,
            \\ALTER TABLE {s}.{s}
            \\ADD COLUMN IF NOT EXISTS version UInt64 DEFAULT generateSnowflakeID()
        , .{ self.db_q, self.table_q });
        defer self.allocator.free(alter_memories_version);
        try self.executeStatement(alter_memories_version, &.{});

        const alter_memories_value_kind = try std.fmt.allocPrint(self.allocator,
            \\ALTER TABLE {s}.{s}
            \\ADD COLUMN IF NOT EXISTS value_kind String DEFAULT ''
        , .{ self.db_q, self.table_q });
        defer self.allocator.free(alter_memories_value_kind);
        try self.executeStatement(alter_memories_value_kind, &.{});

        const alter_memories_event_ts = try std.fmt.allocPrint(self.allocator,
            \\ALTER TABLE {s}.{s}
            \\ADD COLUMN IF NOT EXISTS event_timestamp_ms Int64 DEFAULT 0
        , .{ self.db_q, self.table_q });
        defer self.allocator.free(alter_memories_event_ts);
        try self.executeStatement(alter_memories_event_ts, &.{});

        const alter_memories_event_origin = try std.fmt.allocPrint(self.allocator,
            \\ALTER TABLE {s}.{s}
            \\ADD COLUMN IF NOT EXISTS event_origin_instance_id String DEFAULT 'default'
        , .{ self.db_q, self.table_q });
        defer self.allocator.free(alter_memories_event_origin);
        try self.executeStatement(alter_memories_event_origin, &.{});

        const alter_memories_event_seq = try std.fmt.allocPrint(self.allocator,
            \\ALTER TABLE {s}.{s}
            \\ADD COLUMN IF NOT EXISTS event_origin_sequence UInt64 DEFAULT 0
        , .{ self.db_q, self.table_q });
        defer self.allocator.free(alter_memories_event_seq);
        try self.executeStatement(alter_memories_event_seq, &.{});

        const modify_memories_version = try std.fmt.allocPrint(self.allocator,
            \\ALTER TABLE {s}.{s}
            \\MODIFY COLUMN version UInt64 DEFAULT generateSnowflakeID()
        , .{ self.db_q, self.table_q });
        defer self.allocator.free(modify_memories_version);
        try self.executeStatement(modify_memories_version, &.{});

        const create_events = try std.fmt.allocPrint(self.allocator,
            \\CREATE TABLE IF NOT EXISTS {s}.{s} (
            \\    instance_id String DEFAULT 'default',
            \\    local_sequence UInt64,
            \\    schema_version UInt32 DEFAULT 1,
            \\    origin_instance_id String,
            \\    origin_sequence UInt64,
            \\    timestamp_ms Int64,
            \\    operation String,
            \\    key String,
            \\    session_id String DEFAULT '',
            \\    category String DEFAULT '',
            \\    value_kind String DEFAULT '',
            \\    content String DEFAULT ''
            \\) ENGINE = MergeTree()
            \\ORDER BY (instance_id, local_sequence)
        , .{ self.db_q, self.events_table_q });
        defer self.allocator.free(create_events);
        try self.executeStatement(create_events, &.{});

        const create_frontiers = try std.fmt.allocPrint(self.allocator,
            \\CREATE TABLE IF NOT EXISTS {s}.{s} (
            \\    instance_id String DEFAULT 'default',
            \\    origin_instance_id String,
            \\    last_origin_sequence UInt64,
            \\    version UInt64 DEFAULT generateSnowflakeID()
            \\) ENGINE = ReplacingMergeTree(version)
            \\ORDER BY (instance_id, origin_instance_id)
        , .{ self.db_q, self.frontiers_table_q });
        defer self.allocator.free(create_frontiers);
        try self.executeStatement(create_frontiers, &.{});

        const create_tombstones = try std.fmt.allocPrint(self.allocator,
            \\CREATE TABLE IF NOT EXISTS {s}.{s} (
            \\    instance_id String DEFAULT 'default',
            \\    key String,
            \\    scope String,
            \\    session_key String,
            \\    session_id String DEFAULT '',
            \\    timestamp_ms Int64,
            \\    origin_instance_id String,
            \\    origin_sequence UInt64,
            \\    version UInt64 DEFAULT generateSnowflakeID()
            \\) ENGINE = ReplacingMergeTree(version)
            \\ORDER BY (instance_id, key, scope, session_key)
        , .{ self.db_q, self.tombstones_table_q });
        defer self.allocator.free(create_tombstones);
        try self.executeStatement(create_tombstones, &.{});

        const create_feed_meta = try std.fmt.allocPrint(self.allocator,
            \\CREATE TABLE IF NOT EXISTS {s}.{s} (
            \\    instance_id String DEFAULT 'default',
            \\    meta_key String,
            \\    meta_value String,
            \\    version UInt64 DEFAULT generateSnowflakeID()
            \\) ENGINE = ReplacingMergeTree(version)
            \\ORDER BY (instance_id, meta_key)
        , .{ self.db_q, self.feed_meta_table_q });
        defer self.allocator.free(create_feed_meta);
        try self.executeStatement(create_feed_meta, &.{});

        // 2. Messages table (MergeTree)
        const create_messages = try std.fmt.allocPrint(self.allocator,
            \\CREATE TABLE IF NOT EXISTS {s}.{s} (
            \\    session_id String,
            \\    role String,
            \\    content String,
            \\    instance_id String DEFAULT 'default',
            \\    created_at DateTime64(3) DEFAULT now64(3),
            \\    message_order UInt64 DEFAULT generateSnowflakeID(),
            \\    message_id String DEFAULT ''
            \\) ENGINE = MergeTree()
            \\ORDER BY (instance_id, session_id, message_order, message_id)
        , .{ self.db_q, self.messages_table_q });
        defer self.allocator.free(create_messages);
        try self.executeStatement(create_messages, &.{});

        const alter_messages_order = try std.fmt.allocPrint(self.allocator,
            \\ALTER TABLE {s}.{s}
            \\ADD COLUMN IF NOT EXISTS message_order UInt64 DEFAULT generateSnowflakeID()
        , .{ self.db_q, self.messages_table_q });
        defer self.allocator.free(alter_messages_order);
        try self.executeStatement(alter_messages_order, &.{});

        const modify_messages_order = try std.fmt.allocPrint(self.allocator,
            \\ALTER TABLE {s}.{s}
            \\MODIFY COLUMN message_order UInt64 DEFAULT generateSnowflakeID()
        , .{ self.db_q, self.messages_table_q });
        defer self.allocator.free(modify_messages_order);
        try self.executeStatement(modify_messages_order, &.{});

        const alter_messages_id = try std.fmt.allocPrint(self.allocator,
            \\ALTER TABLE {s}.{s}
            \\ADD COLUMN IF NOT EXISTS message_id String DEFAULT ''
        , .{ self.db_q, self.messages_table_q });
        defer self.allocator.free(alter_messages_id);
        try self.executeStatement(alter_messages_id, &.{});

        // 3. Session usage table (ReplacingMergeTree)
        const create_usage = try std.fmt.allocPrint(self.allocator,
            \\CREATE TABLE IF NOT EXISTS {s}.{s} (
            \\    session_id String,
            \\    instance_id String DEFAULT 'default',
            \\    total_tokens UInt64 DEFAULT 0,
            \\    updated_at DateTime64(3) DEFAULT now64(3),
            \\    version UInt64 DEFAULT generateSnowflakeID()
            \\) ENGINE = ReplacingMergeTree(version)
            \\ORDER BY (instance_id, session_id)
        , .{ self.db_q, self.usage_table_q });
        defer self.allocator.free(create_usage);
        try self.executeStatement(create_usage, &.{});

        const alter_usage_version = try std.fmt.allocPrint(self.allocator,
            \\ALTER TABLE {s}.{s}
            \\ADD COLUMN IF NOT EXISTS version UInt64 DEFAULT generateSnowflakeID()
        , .{ self.db_q, self.usage_table_q });
        defer self.allocator.free(alter_usage_version);
        try self.executeStatement(alter_usage_version, &.{});

        const modify_usage_version = try std.fmt.allocPrint(self.allocator,
            \\ALTER TABLE {s}.{s}
            \\MODIFY COLUMN version UInt64 DEFAULT generateSnowflakeID()
        , .{ self.db_q, self.usage_table_q });
        defer self.allocator.free(modify_usage_version);
        try self.executeStatement(modify_usage_version, &.{});
    }

    // ── Memory vtable implementation ──────────────────────────────

    const ProjectionStateRow = struct {
        content: []u8,
        category: MemoryCategory,
        value_kind: ?MemoryValueKind,
        timestamp_ms: i64,
        origin_instance_id: []u8,
        origin_sequence: u64,

        fn deinit(self: *const ProjectionStateRow, allocator: std.mem.Allocator) void {
            allocator.free(self.content);
            switch (self.category) {
                .custom => |name| allocator.free(name),
                else => {},
            }
            allocator.free(self.origin_instance_id);
        }
    };

    const KeyStateRow = struct {
        session_id: ?[]u8,
        timestamp_ms: i64,
        origin_instance_id: []u8,
        origin_sequence: u64,

        fn deinit(self: *const KeyStateRow, allocator: std.mem.Allocator) void {
            if (self.session_id) |sid| allocator.free(sid);
            allocator.free(self.origin_instance_id);
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

    const CheckpointFrontierRow = struct {
        origin_instance_id: []u8,
        origin_sequence: u64,

        fn deinit(self: *const CheckpointFrontierRow, allocator: std.mem.Allocator) void {
            allocator.free(self.origin_instance_id);
        }
    };

    const CheckpointStateImportRow = struct {
        key: []u8,
        session_id: ?[]u8,
        category: []u8,
        value_kind: ?[]u8,
        content: []u8,
        timestamp_ms: i64,
        origin_instance_id: []u8,
        origin_sequence: u64,

        fn deinit(self: *const CheckpointStateImportRow, allocator: std.mem.Allocator) void {
            allocator.free(self.key);
            if (self.session_id) |sid| allocator.free(sid);
            allocator.free(self.category);
            if (self.value_kind) |kind| allocator.free(kind);
            allocator.free(self.content);
            allocator.free(self.origin_instance_id);
        }
    };

    const CheckpointTombstoneImportRow = struct {
        kind: []u8,
        key: []u8,
        timestamp_ms: i64,
        origin_instance_id: []u8,
        origin_sequence: u64,

        fn deinit(self: *const CheckpointTombstoneImportRow, allocator: std.mem.Allocator) void {
            allocator.free(self.kind);
            allocator.free(self.key);
            allocator.free(self.origin_instance_id);
        }
    };

    fn localInstanceId(self: *Self) []const u8 {
        return self.instance_id;
    }

    fn queryMaybeTrimmed(self: *Self, allocator: std.mem.Allocator, query: []const u8, params: []const [2][]const u8) !?[]u8 {
        const body = try self.executeQuery(allocator, query, params);
        defer allocator.free(body);
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) return null;
        return try allocator.dupe(u8, trimmed);
    }

    fn queryU64(self: *Self, allocator: std.mem.Allocator, query: []const u8, params: []const [2][]const u8) !u64 {
        const trimmed = (try self.queryMaybeTrimmed(allocator, query, params)) orelse return 0;
        defer allocator.free(trimmed);
        return std.fmt.parseInt(u64, trimmed, 10) catch 0;
    }

    fn queryI64(self: *Self, allocator: std.mem.Allocator, query: []const u8, params: []const [2][]const u8) !i64 {
        const trimmed = (try self.queryMaybeTrimmed(allocator, query, params)) orelse return 0;
        defer allocator.free(trimmed);
        return std.fmt.parseInt(i64, trimmed, 10) catch 0;
    }

    fn getMetaU64(self: *Self, allocator: std.mem.Allocator, meta_key: []const u8) !u64 {
        const query = try std.fmt.allocPrint(allocator,
            \\SELECT if(count() = 0, '0', toString(max(toUInt64OrZero(meta_value))))
            \\FROM {s}.{s}
            \\WHERE instance_id = {{iid:String}} AND meta_key = {{meta_key:String}}
        , .{ self.db_q, self.feed_meta_table_q });
        defer allocator.free(query);
        return self.queryU64(allocator, query, &.{
            .{ "iid", self.localInstanceId() },
            .{ "meta_key", meta_key },
        });
    }

    fn setMetaValue(self: *Self, meta_key: []const u8, meta_value: []const u8) !void {
        const query = try std.fmt.allocPrint(self.allocator,
            \\INSERT INTO {s}.{s} (instance_id, meta_key, meta_value)
            \\VALUES ({{iid:String}}, {{meta_key:String}}, {{meta_value:String}})
        , .{ self.db_q, self.feed_meta_table_q });
        defer self.allocator.free(query);
        try self.executeStatement(query, &.{
            .{ "iid", self.localInstanceId() },
            .{ "meta_key", meta_key },
            .{ "meta_value", meta_value },
        });
    }

    fn getCompactedThroughSequence(self: *Self, allocator: std.mem.Allocator) !u64 {
        return self.getMetaU64(allocator, "compacted_through_sequence");
    }

    fn setCompactedThroughSequence(self: *Self, value: u64) !void {
        var buf: [32]u8 = undefined;
        const value_str = try std.fmt.bufPrint(&buf, "{d}", .{value});
        try self.setMetaValue("compacted_through_sequence", value_str);
    }

    fn getProjectedSequence(self: *Self, allocator: std.mem.Allocator) !u64 {
        const value = try self.getMetaU64(allocator, "projected_sequence");
        return if (value > 0) value else try self.getCompactedThroughSequence(allocator);
    }

    fn setProjectedSequence(self: *Self, value: u64) !void {
        var buf: [32]u8 = undefined;
        const value_str = try std.fmt.bufPrint(&buf, "{d}", .{value});
        try self.setMetaValue("projected_sequence", value_str);
    }

    fn getPersistedMaxEventSequence(self: *Self, allocator: std.mem.Allocator) !u64 {
        const query = try std.fmt.allocPrint(allocator,
            \\SELECT if(count() = 0, '', toString(max(local_sequence)))
            \\FROM {s}.{s}
            \\WHERE instance_id = {{iid:String}}
        , .{ self.db_q, self.events_table_q });
        defer allocator.free(query);
        return self.queryU64(allocator, query, &.{.{ "iid", self.localInstanceId() }});
    }

    fn getLastSequence(self: *Self, allocator: std.mem.Allocator) !u64 {
        var last: u64 = try self.getCompactedThroughSequence(allocator);
        last = @max(last, try self.getPersistedMaxEventSequence(allocator));
        last = @max(last, try self.getMetaU64(allocator, "last_sequence"));
        return last;
    }

    fn setLastSequence(self: *Self, value: u64) !void {
        var buf: [32]u8 = undefined;
        const value_str = try std.fmt.bufPrint(&buf, "{d}", .{value});
        try self.setMetaValue("last_sequence", value_str);
    }

    fn getFrontier(self: *Self, allocator: std.mem.Allocator, origin_instance_id: []const u8) !u64 {
        const query = try std.fmt.allocPrint(allocator,
            \\SELECT if(count() = 0, '0', toString(max(last_origin_sequence)))
            \\FROM {s}.{s}
            \\WHERE instance_id = {{iid:String}} AND origin_instance_id = {{origin:String}}
        , .{ self.db_q, self.frontiers_table_q });
        defer allocator.free(query);
        return self.queryU64(allocator, query, &.{
            .{ "iid", self.localInstanceId() },
            .{ "origin", origin_instance_id },
        });
    }

    fn setFrontier(self: *Self, allocator: std.mem.Allocator, origin_instance_id: []const u8, origin_sequence: u64) !void {
        const current = try self.getFrontier(allocator, origin_instance_id);
        if (origin_sequence <= current) return;

        var seq_buf: [32]u8 = undefined;
        const seq_str = try std.fmt.bufPrint(&seq_buf, "{d}", .{origin_sequence});
        const query = try std.fmt.allocPrint(self.allocator,
            \\INSERT INTO {s}.{s} (instance_id, origin_instance_id, last_origin_sequence)
            \\VALUES ({{iid:String}}, {{origin:String}}, {{seq:UInt64}})
        , .{ self.db_q, self.frontiers_table_q });
        defer self.allocator.free(query);
        try self.executeStatement(query, &.{
            .{ "iid", self.localInstanceId() },
            .{ "origin", origin_instance_id },
            .{ "seq", seq_str },
        });
    }

    fn nextLocalOriginSequence(self: *Self, allocator: std.mem.Allocator) !u64 {
        return (try self.getFrontier(allocator, self.localInstanceId())) + 1;
    }

    fn nextEventSequence(self: *Self, allocator: std.mem.Allocator) !u64 {
        const generated = try self.queryU64(allocator, "SELECT toString(generateSnowflakeID())", &.{});
        const current = try self.getLastSequence(allocator);
        return if (generated > current) generated else current + 1;
    }

    fn sessionKeyFor(session_id: ?[]const u8) []const u8 {
        return session_id orelse "";
    }

    fn readEventFromRow(allocator: std.mem.Allocator, row: []const []const u8) !MemoryEvent {
        if (row.len < 11) return error.InvalidEvent;
        const schema_version = std.fmt.parseInt(u32, row[1], 10) catch return error.InvalidEvent;
        if (schema_version != 1) return error.InvalidEvent;
        return .{
            .schema_version = schema_version,
            .sequence = std.fmt.parseInt(u64, row[0], 10) catch return error.InvalidEvent,
            .origin_instance_id = try allocator.dupe(u8, row[2]),
            .origin_sequence = std.fmt.parseInt(u64, row[3], 10) catch return error.InvalidEvent,
            .timestamp_ms = std.fmt.parseInt(i64, row[4], 10) catch return error.InvalidEvent,
            .operation = MemoryEventOp.fromString(row[5]) orelse return error.InvalidEvent,
            .key = try allocator.dupe(u8, row[6]),
            .session_id = if (row[7].len > 0) try allocator.dupe(u8, row[7]) else null,
            .category = if (row[8].len > 0) try parseCategoryOwned(allocator, row[8]) else null,
            .value_kind = try parseValueKind(row[9]),
            .content = if (row[10].len > 0) try allocator.dupe(u8, row[10]) else null,
        };
    }

    fn listEventsInternal(self: *Self, allocator: std.mem.Allocator, after_sequence: u64, limit: usize) ![]MemoryEvent {
        const compacted_through = try self.getCompactedThroughSequence(allocator);
        if (after_sequence < compacted_through) return error.CursorExpired;

        var after_buf: [32]u8 = undefined;
        const after_str = try std.fmt.bufPrint(&after_buf, "{d}", .{after_sequence});
        var limit_buf: [32]u8 = undefined;
        const limit_str = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});

        const query = try std.fmt.allocPrint(allocator,
            \\SELECT local_sequence, toString(schema_version), origin_instance_id, toString(origin_sequence), toString(timestamp_ms), operation, key, session_id, category, value_kind, content
            \\FROM {s}.{s}
            \\WHERE instance_id = {{iid:String}} AND local_sequence > {{after:UInt64}}
            \\ORDER BY local_sequence ASC
            \\LIMIT {{limit:UInt64}}
        , .{ self.db_q, self.events_table_q });
        defer allocator.free(query);

        const body = try self.executeQuery(allocator, query, &.{
            .{ "iid", self.localInstanceId() },
            .{ "after", after_str },
            .{ "limit", limit_str },
        });
        defer allocator.free(body);

        const rows = try parseTsvRows(allocator, body);
        defer freeTsvRows(allocator, rows);

        var events: std.ArrayListUnmanaged(MemoryEvent) = .empty;
        errdefer {
            for (events.items) |*event| event.deinit(allocator);
            events.deinit(allocator);
        }
        for (rows) |row| {
            try events.append(allocator, try readEventFromRow(allocator, row));
        }
        return events.toOwnedSlice(allocator);
    }

    fn readProjectionState(self: *Self, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8) !?ProjectionStateRow {
        const sid = session_id orelse "";
        const query = try std.fmt.allocPrint(allocator,
            \\SELECT content, category, value_kind, toString(event_timestamp_ms), event_origin_instance_id, toString(event_origin_sequence)
            \\FROM (
            \\    SELECT
            \\        argMax(content, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS content,
            \\        argMax(category, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS category,
            \\        argMax(value_kind, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS value_kind,
            \\        argMax(event_timestamp_ms, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS event_timestamp_ms,
            \\        argMax(event_origin_instance_id, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS event_origin_instance_id,
            \\        argMax(event_origin_sequence, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS event_origin_sequence
            \\    FROM {s}.{s}
            \\    WHERE instance_id = {{iid:String}} AND key = {{key:String}} AND session_id = {{sid:String}}
            \\    GROUP BY key, session_id
            \\)
            \\LIMIT 1
        , .{ self.db_q, self.table_q });
        defer allocator.free(query);

        const body = try self.executeQuery(allocator, query, &.{
            .{ "iid", self.localInstanceId() },
            .{ "key", key },
            .{ "sid", sid },
        });
        defer allocator.free(body);

        const rows = try parseTsvRows(allocator, body);
        defer freeTsvRows(allocator, rows);
        if (rows.len == 0) return null;

        return .{
            .content = try allocator.dupe(u8, rows[0][0]),
            .category = try parseCategoryOwned(allocator, rows[0][1]),
            .value_kind = try parseValueKind(rows[0][2]),
            .timestamp_ms = std.fmt.parseInt(i64, rows[0][3], 10) catch 0,
            .origin_instance_id = try allocator.dupe(u8, rows[0][4]),
            .origin_sequence = std.fmt.parseInt(u64, rows[0][5], 10) catch 0,
        };
    }

    fn listKeyStateRows(self: *Self, allocator: std.mem.Allocator, key: []const u8) ![]KeyStateRow {
        const query = try std.fmt.allocPrint(allocator,
            \\SELECT session_id, toString(event_timestamp_ms), event_origin_instance_id, toString(event_origin_sequence)
            \\FROM (
            \\    SELECT
            \\        session_id,
            \\        argMax(event_timestamp_ms, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS event_timestamp_ms,
            \\        argMax(event_origin_instance_id, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS event_origin_instance_id,
            \\        argMax(event_origin_sequence, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS event_origin_sequence
            \\    FROM {s}.{s}
            \\    WHERE instance_id = {{iid:String}} AND key = {{key:String}}
            \\    GROUP BY key, session_id
            \\)
            \\ORDER BY session_id ASC
        , .{ self.db_q, self.table_q });
        defer allocator.free(query);

        const body = try self.executeQuery(allocator, query, &.{
            .{ "iid", self.localInstanceId() },
            .{ "key", key },
        });
        defer allocator.free(body);

        const rows = try parseTsvRows(allocator, body);
        defer freeTsvRows(allocator, rows);

        var out: std.ArrayListUnmanaged(KeyStateRow) = .empty;
        errdefer {
            for (out.items) |*row| row.deinit(allocator);
            out.deinit(allocator);
        }
        for (rows) |row| {
            try out.append(allocator, .{
                .session_id = if (row[0].len > 0) try allocator.dupe(u8, row[0]) else null,
                .timestamp_ms = std.fmt.parseInt(i64, row[1], 10) catch 0,
                .origin_instance_id = try allocator.dupe(u8, row[2]),
                .origin_sequence = std.fmt.parseInt(u64, row[3], 10) catch 0,
            });
        }
        return out.toOwnedSlice(allocator);
    }

    fn getTombstoneMeta(self: *Self, allocator: std.mem.Allocator, key: []const u8, scope: []const u8, session_key: []const u8) !?TombstoneMeta {
        const query = try std.fmt.allocPrint(allocator,
            \\SELECT
            \\    toString(argMax(timestamp_ms, tuple(timestamp_ms, origin_instance_id, origin_sequence, version))),
            \\    argMax(origin_instance_id, tuple(timestamp_ms, origin_instance_id, origin_sequence, version)),
            \\    toString(argMax(origin_sequence, tuple(timestamp_ms, origin_instance_id, origin_sequence, version)))
            \\FROM {s}.{s}
            \\WHERE instance_id = {{iid:String}} AND key = {{key:String}} AND scope = {{scope:String}} AND session_key = {{session_key:String}}
            \\HAVING count() > 0
        , .{ self.db_q, self.tombstones_table_q });
        defer allocator.free(query);

        const body = try self.executeQuery(allocator, query, &.{
            .{ "iid", self.localInstanceId() },
            .{ "key", key },
            .{ "scope", scope },
            .{ "session_key", session_key },
        });
        defer allocator.free(body);
        const rows = try parseTsvRows(allocator, body);
        defer freeTsvRows(allocator, rows);
        if (rows.len == 0) return null;
        return .{
            .timestamp_ms = std.fmt.parseInt(i64, rows[0][0], 10) catch 0,
            .origin_instance_id = try allocator.dupe(u8, rows[0][1]),
            .origin_sequence = std.fmt.parseInt(u64, rows[0][2], 10) catch 0,
        };
    }

    fn tombstoneBlocksPut(self: *Self, input: MemoryEventInput) !bool {
        if (try self.getTombstoneMeta(self.allocator, input.key, "scoped", sessionKeyFor(input.session_id))) |meta| {
            defer meta.deinit(self.allocator);
            if (compareInputToMetadata(input, meta.timestamp_ms, meta.origin_instance_id, meta.origin_sequence) <= 0) return true;
        }
        if (try self.getTombstoneMeta(self.allocator, input.key, "all", "*")) |meta| {
            defer meta.deinit(self.allocator);
            if (compareInputToMetadata(input, meta.timestamp_ms, meta.origin_instance_id, meta.origin_sequence) <= 0) return true;
        }
        return false;
    }

    fn insertStateProjection(self: *Self, key: []const u8, session_id: ?[]const u8, state: ResolvedMemoryState, input: MemoryEventInput) !void {
        const id = try generateId(self.allocator);
        defer self.allocator.free(id);
        const category = state.category.toString();
        const value_kind = if (state.value_kind) |kind| kind.toString() else "";
        const sid = session_id orelse "";
        var ts_buf: [32]u8 = undefined;
        const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{input.timestamp_ms});
        var origin_seq_buf: [32]u8 = undefined;
        const origin_seq_str = try std.fmt.bufPrint(&origin_seq_buf, "{d}", .{input.origin_sequence});

        const query = try std.fmt.allocPrint(self.allocator,
            \\INSERT INTO {s}.{s} (id, key, content, category, value_kind, session_id, instance_id, event_timestamp_ms, event_origin_instance_id, event_origin_sequence, created_at, updated_at)
            \\VALUES (
            \\    {{id:String}}, {{key:String}}, {{content:String}}, {{category:String}}, {{value_kind:String}}, {{sid:String}}, {{iid:String}},
            \\    {{event_timestamp_ms:Int64}}, {{origin_instance_id:String}}, {{origin_sequence:UInt64}},
            \\    fromUnixTimestamp64Milli({{event_timestamp_ms:Int64}}), fromUnixTimestamp64Milli({{event_timestamp_ms:Int64}})
            \\)
        , .{ self.db_q, self.table_q });
        defer self.allocator.free(query);
        try self.executeStatement(query, &.{
            .{ "id", id },
            .{ "key", key },
            .{ "content", state.content },
            .{ "category", category },
            .{ "value_kind", value_kind },
            .{ "sid", sid },
            .{ "iid", self.localInstanceId() },
            .{ "event_timestamp_ms", ts_str },
            .{ "origin_instance_id", input.origin_instance_id },
            .{ "origin_sequence", origin_seq_str },
        });
    }

    fn applyPutProjection(self: *Self, input: MemoryEventInput) !void {
        if (try self.tombstoneBlocksPut(input)) return;

        const existing = try self.readProjectionState(self.allocator, input.key, input.session_id);
        defer if (existing) |row| row.deinit(self.allocator);
        if (existing) |row| {
            if (compareInputToMetadata(input, row.timestamp_ms, row.origin_instance_id, row.origin_sequence) <= 0) return;
        }

        const resolved_state = try root.resolveMemoryEventState(
            self.allocator,
            if (existing) |row| row.content else null,
            if (existing) |row| row.category else null,
            if (existing) |row| row.value_kind else null,
            input,
        ) orelse return error.InvalidEvent;
        defer resolved_state.deinit(self.allocator);
        try self.insertStateProjection(input.key, input.session_id, resolved_state, input);
    }

    fn deleteScopedProjection(self: *Self, input: MemoryEventInput) !void {
        const existing = try self.readProjectionState(self.allocator, input.key, input.session_id);
        defer if (existing) |row| row.deinit(self.allocator);
        if (existing) |row| {
            if (compareInputToMetadata(input, row.timestamp_ms, row.origin_instance_id, row.origin_sequence) < 0) return;
            const query = try std.fmt.allocPrint(self.allocator,
                \\ALTER TABLE {s}.{s} DELETE
                \\WHERE key = {{key:String}} AND session_id = {{sid:String}} AND instance_id = {{iid:String}}
            , .{ self.db_q, self.table_q });
            defer self.allocator.free(query);
            try self.executeMutation(query, &.{
                .{ "key", input.key },
                .{ "sid", sessionKeyFor(input.session_id) },
                .{ "iid", self.localInstanceId() },
            });
        }
    }

    fn deleteAllProjection(self: *Self, input: MemoryEventInput) !void {
        const rows = try self.listKeyStateRows(self.allocator, input.key);
        defer {
            for (rows) |*row| row.deinit(self.allocator);
            self.allocator.free(rows);
        }
        for (rows) |row| {
            if (compareInputToMetadata(input, row.timestamp_ms, row.origin_instance_id, row.origin_sequence) < 0) continue;
            const query = try std.fmt.allocPrint(self.allocator,
                \\ALTER TABLE {s}.{s} DELETE
                \\WHERE key = {{key:String}} AND session_id = {{sid:String}} AND instance_id = {{iid:String}}
            , .{ self.db_q, self.table_q });
            defer self.allocator.free(query);
            try self.executeMutation(query, &.{
                .{ "key", input.key },
                .{ "sid", sessionKeyFor(row.session_id) },
                .{ "iid", self.localInstanceId() },
            });
        }
    }

    fn upsertTombstone(self: *Self, input: MemoryEventInput, scope: []const u8, session_key: []const u8, session_id: ?[]const u8) !void {
        if (try self.getTombstoneMeta(self.allocator, input.key, scope, session_key)) |meta| {
            defer meta.deinit(self.allocator);
            if (compareInputToMetadata(input, meta.timestamp_ms, meta.origin_instance_id, meta.origin_sequence) <= 0) return;
        }

        var ts_buf: [32]u8 = undefined;
        const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{input.timestamp_ms});
        var origin_seq_buf: [32]u8 = undefined;
        const origin_seq_str = try std.fmt.bufPrint(&origin_seq_buf, "{d}", .{input.origin_sequence});
        const sid = session_id orelse "";
        const query = try std.fmt.allocPrint(self.allocator,
            \\INSERT INTO {s}.{s} (instance_id, key, scope, session_key, session_id, timestamp_ms, origin_instance_id, origin_sequence)
            \\VALUES ({{iid:String}}, {{key:String}}, {{scope:String}}, {{session_key:String}}, {{session_id:String}}, {{timestamp_ms:Int64}}, {{origin_instance_id:String}}, {{origin_sequence:UInt64}})
        , .{ self.db_q, self.tombstones_table_q });
        defer self.allocator.free(query);
        try self.executeStatement(query, &.{
            .{ "iid", self.localInstanceId() },
            .{ "key", input.key },
            .{ "scope", scope },
            .{ "session_key", session_key },
            .{ "session_id", sid },
            .{ "timestamp_ms", ts_str },
            .{ "origin_instance_id", input.origin_instance_id },
            .{ "origin_sequence", origin_seq_str },
        });
    }

    fn appendNativeEvent(self: *Self, input: MemoryEventInput) !u64 {
        const local_sequence = try self.nextEventSequence(self.allocator);
        var local_seq_buf: [32]u8 = undefined;
        const local_seq_str = try std.fmt.bufPrint(&local_seq_buf, "{d}", .{local_sequence});
        var origin_seq_buf: [32]u8 = undefined;
        const origin_seq_str = try std.fmt.bufPrint(&origin_seq_buf, "{d}", .{input.origin_sequence});
        var ts_buf: [32]u8 = undefined;
        const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{input.timestamp_ms});
        const sid = sessionKeyFor(input.session_id);
        const category = if (input.category) |value| value.toString() else "";
        const value_kind = if (input.value_kind) |value| value.toString() else "";
        const content = input.content orelse "";

        const query = try std.fmt.allocPrint(self.allocator,
            \\INSERT INTO {s}.{s} (instance_id, local_sequence, schema_version, origin_instance_id, origin_sequence, timestamp_ms, operation, key, session_id, category, value_kind, content)
            \\VALUES ({{iid:String}}, {{local_sequence:UInt64}}, 1, {{origin_instance_id:String}}, {{origin_sequence:UInt64}}, {{timestamp_ms:Int64}}, {{operation:String}}, {{key:String}}, {{session_id:String}}, {{category:String}}, {{value_kind:String}}, {{content:String}})
        , .{ self.db_q, self.events_table_q });
        defer self.allocator.free(query);
        try self.executeStatement(query, &.{
            .{ "iid", self.localInstanceId() },
            .{ "local_sequence", local_seq_str },
            .{ "origin_instance_id", input.origin_instance_id },
            .{ "origin_sequence", origin_seq_str },
            .{ "timestamp_ms", ts_str },
            .{ "operation", input.operation.toString() },
            .{ "key", input.key },
            .{ "session_id", sid },
            .{ "category", category },
            .{ "value_kind", value_kind },
            .{ "content", content },
        });
        try self.setLastSequence(local_sequence);
        return local_sequence;
    }

    fn applyProjectionEvent(self: *Self, input: MemoryEventInput) !void {
        switch (input.operation) {
            .put, .merge_object, .merge_string_set => try self.applyPutProjection(input),
            .delete_scoped => {
                try self.deleteScopedProjection(input);
                try self.upsertTombstone(input, "scoped", sessionKeyFor(input.session_id), input.session_id);
            },
            .delete_all => {
                try self.deleteAllProjection(input);
                try self.upsertTombstone(input, "all", "*", null);
            },
        }
        try self.setFrontier(self.allocator, input.origin_instance_id, input.origin_sequence);
    }

    fn recordAndProjectEvent(self: *Self, input: MemoryEventInput) !void {
        const local_sequence = try self.appendNativeEvent(input);
        try self.applyProjectionEvent(input);
        try self.setProjectedSequence(local_sequence);
    }

    fn ensureProjectionUpToDate(self: *Self) !void {
        const last_sequence = try self.getLastSequence(self.allocator);
        var projected_sequence = try self.getProjectedSequence(self.allocator);
        const compacted_through = try self.getCompactedThroughSequence(self.allocator);
        if (projected_sequence < compacted_through) projected_sequence = compacted_through;

        while (projected_sequence < last_sequence) {
            const events = try self.listEventsInternal(self.allocator, projected_sequence, 128);
            defer root.freeEvents(self.allocator, events);
            if (events.len == 0) return error.CursorExpired;

            for (events) |event| {
                const input = MemoryEventInput{
                    .origin_instance_id = event.origin_instance_id,
                    .origin_sequence = event.origin_sequence,
                    .timestamp_ms = event.timestamp_ms,
                    .operation = event.operation,
                    .key = event.key,
                    .session_id = event.session_id,
                    .category = event.category,
                    .value_kind = event.value_kind,
                    .content = event.content,
                };
                try self.applyProjectionEvent(input);
                projected_sequence = event.sequence;
                try self.setProjectedSequence(projected_sequence);
            }
        }
    }

    fn bootstrapFeedFromExistingState(self: *Self) !void {
        if (try self.getLastSequence(self.allocator) > 0) return;
        if (try self.getCompactedThroughSequence(self.allocator) > 0) return;

        const query = try std.fmt.allocPrint(self.allocator,
            \\SELECT key, session_id, content, category, value_kind, toString(toUnixTimestamp64Milli(argMax(updated_at, tuple(version, id))))
            \\FROM (
            \\    SELECT
            \\        key,
            \\        session_id,
            \\        argMax(content, tuple(version, id)) AS content,
            \\        argMax(category, tuple(version, id)) AS category,
            \\        argMax(value_kind, tuple(version, id)) AS value_kind,
            \\        argMax(updated_at, tuple(version, id)) AS updated_at
            \\    FROM {s}.{s}
            \\    WHERE instance_id = {{iid:String}}
            \\    GROUP BY key, session_id
            \\)
            \\ORDER BY key ASC, session_id ASC
        , .{ self.db_q, self.table_q });
        defer self.allocator.free(query);

        const body = try self.executeQuery(self.allocator, query, &.{.{ "iid", self.localInstanceId() }});
        defer self.allocator.free(body);
        const rows = try parseTsvRows(self.allocator, body);
        defer freeTsvRows(self.allocator, rows);
        if (rows.len == 0) return;

        var origin_sequence: u64 = 1;
        for (rows) |row| {
            const category = try parseCategoryOwned(self.allocator, row[3]);
            defer switch (category) {
                .custom => |name| self.allocator.free(name),
                else => {},
            };
            try self.recordAndProjectEvent(.{
                .origin_instance_id = self.localInstanceId(),
                .origin_sequence = origin_sequence,
                .timestamp_ms = std.fmt.parseInt(i64, row[5], 10) catch std.time.milliTimestamp(),
                .operation = .put,
                .key = row[0],
                .session_id = if (row[1].len > 0) row[1] else null,
                .category = category,
                .value_kind = try parseValueKind(row[4]),
                .content = row[2],
            });
            origin_sequence += 1;
        }
    }

    fn clearNativeFeedAndProjection(self: *Self) !void {
        const delete_tables = [_][]const u8{
            self.table_q,
            self.events_table_q,
            self.frontiers_table_q,
            self.tombstones_table_q,
            self.feed_meta_table_q,
        };
        for (delete_tables) |table_q| {
            const query = try std.fmt.allocPrint(self.allocator,
                \\ALTER TABLE {s}.{s} DELETE
                \\WHERE instance_id = {{iid:String}}
            , .{ self.db_q, table_q });
            defer self.allocator.free(query);
            try self.executeMutation(query, &.{.{ "iid", self.localInstanceId() }});
        }
    }

    fn checkpointJsonStringField(val: std.json.Value, key: []const u8) ?[]const u8 {
        if (val != .object) return null;
        const field = val.object.get(key) orelse return null;
        return if (field == .string) field.string else null;
    }

    fn checkpointJsonNullableStringField(val: std.json.Value, key: []const u8) ?[]const u8 {
        if (val != .object) return null;
        const field = val.object.get(key) orelse return null;
        if (field == .null) return null;
        return if (field == .string) field.string else null;
    }

    fn checkpointJsonIntegerField(val: std.json.Value, key: []const u8) ?i64 {
        if (val != .object) return null;
        const field = val.object.get(key) orelse return null;
        return switch (field) {
            .integer => field.integer,
            else => null,
        };
    }

    fn checkpointJsonUnsignedField(val: std.json.Value, key: []const u8) ?u64 {
        const value = checkpointJsonIntegerField(val, key) orelse return null;
        if (value < 0) return null;
        return @intCast(value);
    }

    fn appendCheckpointMetaLine(
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(u8),
        last_sequence: u64,
        last_timestamp_ms: i64,
    ) !void {
        try out.append(allocator, '{');
        try json_util.appendJsonKeyValue(out, allocator, "kind", "meta");
        try out.append(allocator, ',');
        try json_util.appendJsonInt(out, allocator, "schema_version", 1);
        try out.append(allocator, ',');
        try json_util.appendJsonKey(out, allocator, "last_sequence");
        try out.writer(allocator).print("{d}", .{last_sequence});
        try out.append(allocator, ',');
        try json_util.appendJsonKey(out, allocator, "last_timestamp_ms");
        try out.writer(allocator).print("{d}", .{last_timestamp_ms});
        try out.append(allocator, ',');
        try json_util.appendJsonKey(out, allocator, "compacted_through_sequence");
        try out.writer(allocator).print("{d}", .{last_sequence});
        try out.appendSlice(allocator, "}\n");
    }

    fn appendCheckpointFrontierLine(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), origin_instance_id: []const u8, origin_sequence: u64) !void {
        try out.append(allocator, '{');
        try json_util.appendJsonKeyValue(out, allocator, "kind", "frontier");
        try out.append(allocator, ',');
        try json_util.appendJsonKeyValue(out, allocator, "origin_instance_id", origin_instance_id);
        try out.append(allocator, ',');
        try json_util.appendJsonKey(out, allocator, "origin_sequence");
        try out.writer(allocator).print("{d}", .{origin_sequence});
        try out.appendSlice(allocator, "}\n");
    }

    fn appendCheckpointStateLine(
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(u8),
        key: []const u8,
        session_id: ?[]const u8,
        category: []const u8,
        value_kind: ?[]const u8,
        content: []const u8,
        timestamp_ms: i64,
        origin_instance_id: []const u8,
        origin_sequence: u64,
    ) !void {
        try out.append(allocator, '{');
        try json_util.appendJsonKeyValue(out, allocator, "kind", "state");
        try out.append(allocator, ',');
        try json_util.appendJsonKeyValue(out, allocator, "key", key);
        try out.append(allocator, ',');
        try json_util.appendJsonKey(out, allocator, "session_id");
        if (session_id) |sid| {
            try json_util.appendJsonString(out, allocator, sid);
        } else {
            try out.appendSlice(allocator, "null");
        }
        try out.append(allocator, ',');
        try json_util.appendJsonKeyValue(out, allocator, "category", category);
        try out.append(allocator, ',');
        try json_util.appendJsonKey(out, allocator, "value_kind");
        if (value_kind) |kind| {
            try json_util.appendJsonString(out, allocator, kind);
        } else {
            try out.appendSlice(allocator, "null");
        }
        try out.append(allocator, ',');
        try json_util.appendJsonKeyValue(out, allocator, "content", content);
        try out.append(allocator, ',');
        try json_util.appendJsonKey(out, allocator, "timestamp_ms");
        try out.writer(allocator).print("{d}", .{timestamp_ms});
        try out.append(allocator, ',');
        try json_util.appendJsonKeyValue(out, allocator, "origin_instance_id", origin_instance_id);
        try out.append(allocator, ',');
        try json_util.appendJsonKey(out, allocator, "origin_sequence");
        try out.writer(allocator).print("{d}", .{origin_sequence});
        try out.appendSlice(allocator, "}\n");
    }

    fn appendCheckpointTombstoneLine(
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(u8),
        kind: []const u8,
        key: []const u8,
        timestamp_ms: i64,
        origin_instance_id: []const u8,
        origin_sequence: u64,
    ) !void {
        try out.append(allocator, '{');
        try json_util.appendJsonKeyValue(out, allocator, "kind", kind);
        try out.append(allocator, ',');
        try json_util.appendJsonKeyValue(out, allocator, "key", key);
        try out.append(allocator, ',');
        try json_util.appendJsonKey(out, allocator, "timestamp_ms");
        try out.writer(allocator).print("{d}", .{timestamp_ms});
        try out.append(allocator, ',');
        try json_util.appendJsonKeyValue(out, allocator, "origin_instance_id", origin_instance_id);
        try out.append(allocator, ',');
        try json_util.appendJsonKey(out, allocator, "origin_sequence");
        try out.writer(allocator).print("{d}", .{origin_sequence});
        try out.appendSlice(allocator, "}\n");
    }

    fn exportCheckpointPayload(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        try self.ensureProjectionUpToDate();

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        const last_sequence = try self.getLastSequence(allocator);
        const state_max_ts = blk: {
            const query = try std.fmt.allocPrint(allocator,
                \\SELECT if(count() = 0, '0', toString(max(event_timestamp_ms)))
                \\FROM {s}.{s}
                \\WHERE instance_id = {{iid:String}}
            , .{ self.db_q, self.table_q });
            defer allocator.free(query);
            break :blk try self.queryI64(allocator, query, &.{.{ "iid", self.localInstanceId() }});
        };
        const tombstone_max_ts = blk: {
            const query = try std.fmt.allocPrint(allocator,
                \\SELECT if(count() = 0, '0', toString(max(timestamp_ms)))
                \\FROM {s}.{s}
                \\WHERE instance_id = {{iid:String}}
            , .{ self.db_q, self.tombstones_table_q });
            defer allocator.free(query);
            break :blk try self.queryI64(allocator, query, &.{.{ "iid", self.localInstanceId() }});
        };
        try appendCheckpointMetaLine(allocator, &out, last_sequence, @max(state_max_ts, tombstone_max_ts));

        {
            const query = try std.fmt.allocPrint(allocator,
                \\SELECT origin_instance_id, toString(max(last_origin_sequence))
                \\FROM {s}.{s}
                \\WHERE instance_id = {{iid:String}}
                \\GROUP BY origin_instance_id
                \\ORDER BY origin_instance_id ASC
            , .{ self.db_q, self.frontiers_table_q });
            defer allocator.free(query);
            const body = try self.executeQuery(allocator, query, &.{.{ "iid", self.localInstanceId() }});
            defer allocator.free(body);
            const rows = try parseTsvRows(allocator, body);
            defer freeTsvRows(allocator, rows);
            for (rows) |row| {
                try appendCheckpointFrontierLine(allocator, &out, row[0], std.fmt.parseInt(u64, row[1], 10) catch 0);
            }
        }

        {
            const query = try std.fmt.allocPrint(allocator,
                \\SELECT key, session_id, content, category, value_kind, toString(event_timestamp_ms), event_origin_instance_id, toString(event_origin_sequence)
                \\FROM (
                \\    SELECT
                \\        argMax(id, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS id,
                \\        key,
                \\        argMax(content, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS content,
                \\        argMax(category, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS category,
                \\        argMax(value_kind, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS value_kind,
                \\        session_id,
                \\        argMax(event_timestamp_ms, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS event_timestamp_ms,
                \\        argMax(event_origin_instance_id, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS event_origin_instance_id,
                \\        argMax(event_origin_sequence, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS event_origin_sequence
                \\    FROM {s}.{s}
                \\    WHERE instance_id = {{iid:String}}
                \\    GROUP BY key, session_id
                \\)
                \\ORDER BY key ASC, session_id ASC
            , .{ self.db_q, self.table_q });
            defer allocator.free(query);
            const body = try self.executeQuery(allocator, query, &.{.{ "iid", self.localInstanceId() }});
            defer allocator.free(body);
            const rows = try parseTsvRows(allocator, body);
            defer freeTsvRows(allocator, rows);
            for (rows) |row| {
                try appendCheckpointStateLine(
                    allocator,
                    &out,
                    row[0],
                    if (row[1].len > 0) row[1] else null,
                    row[3],
                    if (row[4].len > 0) row[4] else null,
                    row[2],
                    std.fmt.parseInt(i64, row[5], 10) catch 0,
                    row[6],
                    std.fmt.parseInt(u64, row[7], 10) catch 0,
                );
            }
        }

        {
            const query = try std.fmt.allocPrint(allocator,
                \\SELECT
                \\    key,
                \\    scope,
                \\    session_id,
                \\    session_key,
                \\    toString(argMax(timestamp_ms, tuple(timestamp_ms, origin_instance_id, origin_sequence, version))),
                \\    argMax(origin_instance_id, tuple(timestamp_ms, origin_instance_id, origin_sequence, version)),
                \\    toString(argMax(origin_sequence, tuple(timestamp_ms, origin_instance_id, origin_sequence, version)))
                \\FROM {s}.{s}
                \\WHERE instance_id = {{iid:String}}
                \\GROUP BY key, scope, session_id, session_key
                \\ORDER BY key ASC, scope ASC, session_key ASC
            , .{ self.db_q, self.tombstones_table_q });
            defer allocator.free(query);
            const body = try self.executeQuery(allocator, query, &.{.{ "iid", self.localInstanceId() }});
            defer allocator.free(body);
            const rows = try parseTsvRows(allocator, body);
            defer freeTsvRows(allocator, rows);
            for (rows) |row| {
                const is_all = std.mem.eql(u8, row[1], "all");
                const encoded_key = if (is_all)
                    try allocator.dupe(u8, row[0])
                else
                    try key_codec.encode(allocator, row[0], if (row[2].len > 0) row[2] else null);
                defer allocator.free(encoded_key);
                try appendCheckpointTombstoneLine(
                    allocator,
                    &out,
                    if (is_all) "key_tombstone" else "scoped_tombstone",
                    encoded_key,
                    std.fmt.parseInt(i64, row[4], 10) catch 0,
                    row[5],
                    std.fmt.parseInt(u64, row[6], 10) catch 0,
                );
            }
        }

        return out.toOwnedSlice(allocator);
    }

    fn insertCheckpointState(
        self: *Self,
        key: []const u8,
        session_id: ?[]const u8,
        category: []const u8,
        value_kind: ?[]const u8,
        content: []const u8,
        timestamp_ms: i64,
        origin_instance_id: []const u8,
        origin_sequence: u64,
    ) !void {
        const id = try generateId(self.allocator);
        defer self.allocator.free(id);
        var ts_buf: [32]u8 = undefined;
        const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{timestamp_ms});
        var origin_seq_buf: [32]u8 = undefined;
        const origin_seq_str = try std.fmt.bufPrint(&origin_seq_buf, "{d}", .{origin_sequence});
        const sid = session_id orelse "";
        const value_kind_str = value_kind orelse "";

        const query = try std.fmt.allocPrint(self.allocator,
            \\INSERT INTO {s}.{s} (id, key, content, category, value_kind, session_id, instance_id, event_timestamp_ms, event_origin_instance_id, event_origin_sequence, created_at, updated_at)
            \\VALUES (
            \\    {{id:String}}, {{key:String}}, {{content:String}}, {{category:String}}, {{value_kind:String}}, {{sid:String}}, {{iid:String}},
            \\    {{timestamp_ms:Int64}}, {{origin_instance_id:String}}, {{origin_sequence:UInt64}},
            \\    fromUnixTimestamp64Milli({{timestamp_ms:Int64}}), fromUnixTimestamp64Milli({{timestamp_ms:Int64}})
            \\)
        , .{ self.db_q, self.table_q });
        defer self.allocator.free(query);
        try self.executeStatement(query, &.{
            .{ "id", id },
            .{ "key", key },
            .{ "content", content },
            .{ "category", category },
            .{ "value_kind", value_kind_str },
            .{ "sid", sid },
            .{ "iid", self.localInstanceId() },
            .{ "timestamp_ms", ts_str },
            .{ "origin_instance_id", origin_instance_id },
            .{ "origin_sequence", origin_seq_str },
        });
    }

    fn insertCheckpointFrontier(self: *Self, origin_instance_id: []const u8, origin_sequence: u64) !void {
        try self.setFrontier(self.allocator, origin_instance_id, origin_sequence);
    }

    fn insertCheckpointTombstone(
        self: *Self,
        kind: []const u8,
        key: []const u8,
        timestamp_ms: i64,
        origin_instance_id: []const u8,
        origin_sequence: u64,
    ) !void {
        const is_all = std.mem.eql(u8, kind, "key_tombstone");
        const decoded = if (is_all)
            key_codec.DecodedVectorKey{ .logical_key = key, .session_id = null, .is_legacy = false }
        else
            key_codec.decode(key);
        if (!is_all and decoded.is_legacy) return error.InvalidEvent;

        var ts_buf: [32]u8 = undefined;
        const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{timestamp_ms});
        var origin_seq_buf: [32]u8 = undefined;
        const origin_seq_str = try std.fmt.bufPrint(&origin_seq_buf, "{d}", .{origin_sequence});
        const session_id = decoded.session_id orelse "";
        const query = try std.fmt.allocPrint(self.allocator,
            \\INSERT INTO {s}.{s} (instance_id, key, scope, session_key, session_id, timestamp_ms, origin_instance_id, origin_sequence)
            \\VALUES ({{iid:String}}, {{key:String}}, {{scope:String}}, {{session_key:String}}, {{session_id:String}}, {{timestamp_ms:Int64}}, {{origin_instance_id:String}}, {{origin_sequence:UInt64}})
        , .{ self.db_q, self.tombstones_table_q });
        defer self.allocator.free(query);
        try self.executeStatement(query, &.{
            .{ "iid", self.localInstanceId() },
            .{ "key", decoded.logical_key },
            .{ "scope", if (is_all) "all" else "scoped" },
            .{ "session_key", if (is_all) "*" else sessionKeyFor(decoded.session_id) },
            .{ "session_id", session_id },
            .{ "timestamp_ms", ts_str },
            .{ "origin_instance_id", origin_instance_id },
            .{ "origin_sequence", origin_seq_str },
        });
    }

    fn applyCheckpointPayload(self: *Self, payload: []const u8) !void {
        var last_sequence: u64 = 0;
        var compacted_through: u64 = 0;
        var saw_meta = false;
        var frontiers: std.ArrayListUnmanaged(CheckpointFrontierRow) = .empty;
        defer {
            for (frontiers.items) |*row| row.deinit(self.allocator);
            frontiers.deinit(self.allocator);
        }
        var states: std.ArrayListUnmanaged(CheckpointStateImportRow) = .empty;
        defer {
            for (states.items) |*row| row.deinit(self.allocator);
            states.deinit(self.allocator);
        }
        var tombstones: std.ArrayListUnmanaged(CheckpointTombstoneImportRow) = .empty;
        defer {
            for (tombstones.items) |*row| row.deinit(self.allocator);
            tombstones.deinit(self.allocator);
        }

        var lines = std.mem.splitScalar(u8, payload, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r\n");
            if (line.len == 0) continue;

            var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, line, .{});
            defer parsed.deinit();

            const kind = checkpointJsonStringField(parsed.value, "kind") orelse return error.InvalidEvent;
            if (std.mem.eql(u8, kind, "meta")) {
                if (saw_meta) return error.InvalidEvent;
                const schema_version = checkpointJsonUnsignedField(parsed.value, "schema_version") orelse return error.InvalidEvent;
                if (schema_version != 1) return error.InvalidEvent;
                saw_meta = true;
                last_sequence = checkpointJsonUnsignedField(parsed.value, "last_sequence") orelse return error.InvalidEvent;
                compacted_through = checkpointJsonUnsignedField(parsed.value, "compacted_through_sequence") orelse return error.InvalidEvent;
                if (compacted_through > last_sequence) return error.InvalidEvent;
                continue;
            }
            if (std.mem.eql(u8, kind, "frontier")) {
                try frontiers.append(self.allocator, .{
                    .origin_instance_id = try self.allocator.dupe(u8, checkpointJsonStringField(parsed.value, "origin_instance_id") orelse return error.InvalidEvent),
                    .origin_sequence = checkpointJsonUnsignedField(parsed.value, "origin_sequence") orelse return error.InvalidEvent,
                });
                continue;
            }
            if (std.mem.eql(u8, kind, "state")) {
                try states.append(self.allocator, .{
                    .key = try self.allocator.dupe(u8, checkpointJsonStringField(parsed.value, "key") orelse return error.InvalidEvent),
                    .session_id = if (checkpointJsonNullableStringField(parsed.value, "session_id")) |sid| try self.allocator.dupe(u8, sid) else null,
                    .category = try self.allocator.dupe(u8, checkpointJsonStringField(parsed.value, "category") orelse return error.InvalidEvent),
                    .value_kind = if (checkpointJsonNullableStringField(parsed.value, "value_kind")) |kind_text| try self.allocator.dupe(u8, kind_text) else null,
                    .content = try self.allocator.dupe(u8, checkpointJsonStringField(parsed.value, "content") orelse return error.InvalidEvent),
                    .timestamp_ms = checkpointJsonIntegerField(parsed.value, "timestamp_ms") orelse return error.InvalidEvent,
                    .origin_instance_id = try self.allocator.dupe(u8, checkpointJsonStringField(parsed.value, "origin_instance_id") orelse return error.InvalidEvent),
                    .origin_sequence = checkpointJsonUnsignedField(parsed.value, "origin_sequence") orelse return error.InvalidEvent,
                });
                continue;
            }
            if (std.mem.eql(u8, kind, "scoped_tombstone") or std.mem.eql(u8, kind, "key_tombstone")) {
                try tombstones.append(self.allocator, .{
                    .kind = try self.allocator.dupe(u8, kind),
                    .key = try self.allocator.dupe(u8, checkpointJsonStringField(parsed.value, "key") orelse return error.InvalidEvent),
                    .timestamp_ms = checkpointJsonIntegerField(parsed.value, "timestamp_ms") orelse return error.InvalidEvent,
                    .origin_instance_id = try self.allocator.dupe(u8, checkpointJsonStringField(parsed.value, "origin_instance_id") orelse return error.InvalidEvent),
                    .origin_sequence = checkpointJsonUnsignedField(parsed.value, "origin_sequence") orelse return error.InvalidEvent,
                });
                continue;
            }
            return error.InvalidEvent;
        }

        if (!saw_meta) return error.InvalidEvent;

        try self.clearNativeFeedAndProjection();
        for (frontiers.items) |row| {
            try self.insertCheckpointFrontier(row.origin_instance_id, row.origin_sequence);
        }
        for (states.items) |row| {
            try self.insertCheckpointState(
                row.key,
                row.session_id,
                row.category,
                row.value_kind,
                row.content,
                row.timestamp_ms,
                row.origin_instance_id,
                row.origin_sequence,
            );
        }
        for (tombstones.items) |row| {
            try self.insertCheckpointTombstone(
                row.kind,
                row.key,
                row.timestamp_ms,
                row.origin_instance_id,
                row.origin_sequence,
            );
        }
        try self.setLastSequence(last_sequence);
        try self.setCompactedThroughSequence(compacted_through);
        try self.setProjectedSequence(last_sequence);
    }

    fn implName(_: *anyopaque) []const u8 {
        return "clickhouse";
    }

    fn emitLocalEvent(self: *Self, operation: MemoryEventOp, key: []const u8, session_id: ?[]const u8, category: ?MemoryCategory, value_kind: ?MemoryValueKind, content: ?[]const u8) !void {
        try self.ensureProjectionUpToDate();
        try self.recordAndProjectEvent(.{
            .origin_instance_id = self.localInstanceId(),
            .origin_sequence = try self.nextLocalOriginSequence(self.allocator),
            .timestamp_ms = std.time.milliTimestamp(),
            .operation = operation,
            .key = key,
            .session_id = session_id,
            .category = category,
            .value_kind = value_kind,
            .content = content,
        });
    }

    fn implStore(ptr: *anyopaque, key: []const u8, content: []const u8, category: MemoryCategory, session_id: ?[]const u8) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.emitLocalEvent(.put, key, session_id, category, null, content);
    }

    fn buildStateSelectQuery(self: *Self, allocator: std.mem.Allocator, comptime where_sql: []const u8, extra_sql: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\SELECT id, key, content, category, toString(updated_at), session_id
            \\FROM (
            \\    SELECT
            \\        argMax(id, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS id,
            \\        key,
            \\        argMax(content, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS content,
            \\        argMax(category, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS category,
            \\        argMax(updated_at, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS updated_at,
            \\        argMax(session_id, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS session_id
            \\    FROM {s}.{s}
            \\    WHERE instance_id = {{iid:String}} {s}
            \\    GROUP BY key, session_id
            \\)
            \\{s}
        , .{ self.db_q, self.table_q, where_sql, extra_sql });
    }

    fn implGet(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.ensureProjectionUpToDate();

        const query = try self_.buildStateSelectQuery(allocator, "AND key = {{key:String}} AND session_id = ''", "LIMIT 1");
        defer allocator.free(query);
        const body = try self_.executeQuery(allocator, query, &.{
            .{ "iid", self_.localInstanceId() },
            .{ "key", key },
        });
        defer allocator.free(body);
        const rows = try parseTsvRows(allocator, body);
        defer freeTsvRows(allocator, rows);
        if (rows.len == 0) return null;
        return try buildEntry(allocator, rows[0]);
    }

    fn implGetScoped(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8, session_id: ?[]const u8) anyerror!?MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.ensureProjectionUpToDate();
        const query = try self_.buildStateSelectQuery(allocator, "AND key = {{key:String}} AND session_id = {{sid:String}}", "LIMIT 1");
        defer allocator.free(query);
        const body = try self_.executeQuery(allocator, query, &.{
            .{ "iid", self_.localInstanceId() },
            .{ "key", key },
            .{ "sid", sessionKeyFor(session_id) },
        });
        defer allocator.free(body);
        const rows = try parseTsvRows(allocator, body);
        defer freeTsvRows(allocator, rows);
        if (rows.len == 0) return null;
        return try buildEntry(allocator, rows[0]);
    }

    fn implRecall(ptr: *anyopaque, allocator: std.mem.Allocator, query_str: []const u8, limit: usize, session_id: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.ensureProjectionUpToDate();

        const trimmed = std.mem.trim(u8, query_str, " \t\n\r");
        if (trimmed.len == 0) return allocator.alloc(MemoryEntry, 0);

        const pattern = try std.fmt.allocPrint(allocator, "%{s}%", .{trimmed});
        defer allocator.free(pattern);
        var limit_buf: [20]u8 = undefined;
        const limit_str = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});

        const query = if (session_id != null)
            try std.fmt.allocPrint(allocator,
                \\SELECT id, key, content, category, toString(updated_at), session_id,
                \\    CASE WHEN key ILIKE {{q:String}} THEN 2.0 ELSE 0.0 END +
                \\    CASE WHEN content ILIKE {{q:String}} THEN 1.0 ELSE 0.0 END AS score
                \\FROM (
                \\    SELECT
                \\        argMax(id, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS id,
                \\        key,
                \\        argMax(content, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS content,
                \\        argMax(category, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS category,
                \\        argMax(updated_at, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS updated_at,
                \\        argMax(session_id, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS session_id
                \\    FROM {s}.{s}
                \\    WHERE instance_id = {{iid:String}}
                \\    GROUP BY key, session_id
                \\)
                \\WHERE (key ILIKE {{q:String}} OR content ILIKE {{q:String}}) AND session_id = {{sid:String}}
                \\ORDER BY score DESC, updated_at DESC, id DESC
                \\LIMIT {{lim:UInt32}}
            , .{ self_.db_q, self_.table_q })
        else
            try std.fmt.allocPrint(allocator,
                \\SELECT id, key, content, category, toString(updated_at), session_id,
                \\    CASE WHEN key ILIKE {{q:String}} THEN 2.0 ELSE 0.0 END +
                \\    CASE WHEN content ILIKE {{q:String}} THEN 1.0 ELSE 0.0 END AS score
                \\FROM (
                \\    SELECT
                \\        argMax(id, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS id,
                \\        key,
                \\        argMax(content, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS content,
                \\        argMax(category, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS category,
                \\        argMax(updated_at, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS updated_at,
                \\        argMax(session_id, tuple(event_timestamp_ms, event_origin_instance_id, event_origin_sequence, version, id)) AS session_id
                \\    FROM {s}.{s}
                \\    WHERE instance_id = {{iid:String}}
                \\    GROUP BY key, session_id
                \\)
                \\WHERE (key ILIKE {{q:String}} OR content ILIKE {{q:String}})
                \\ORDER BY score DESC, updated_at DESC, id DESC
                \\LIMIT {{lim:UInt32}}
            , .{ self_.db_q, self_.table_q });
        defer allocator.free(query);

        const params = if (session_id) |sid|
            &[_][2][]const u8{ .{ "q", pattern }, .{ "iid", self_.localInstanceId() }, .{ "sid", sid }, .{ "lim", limit_str } }
        else
            &[_][2][]const u8{ .{ "q", pattern }, .{ "iid", self_.localInstanceId() }, .{ "lim", limit_str } };
        const body = try self_.executeQuery(allocator, query, params);
        defer allocator.free(body);
        const rows = try parseTsvRows(allocator, body);
        defer freeTsvRows(allocator, rows);

        var entries: std.ArrayList(MemoryEntry) = .empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }
        for (rows) |row| {
            var entry = try buildEntry(allocator, row);
            errdefer entry.deinit(allocator);
            if (row.len > 6) entry.score = std.fmt.parseFloat(f64, row[6]) catch null;
            try entries.append(allocator, entry);
        }
        return entries.toOwnedSlice(allocator);
    }

    fn implList(ptr: *anyopaque, allocator: std.mem.Allocator, category: ?MemoryCategory, session_id: ?[]const u8) anyerror![]MemoryEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.ensureProjectionUpToDate();

        var query: []u8 = undefined;
        var params_buf: [3][2][]const u8 = undefined;
        var param_count: usize = 0;
        params_buf[param_count] = .{ "iid", self_.localInstanceId() };
        param_count += 1;

        if (category) |cat| {
            const cat_str = cat.toString();
            if (session_id) |sid| {
                query = try self_.buildStateSelectQuery(allocator, "AND category = {{cat:String}} AND session_id = {{sid:String}}", "ORDER BY updated_at DESC, id DESC");
                params_buf[param_count] = .{ "cat", cat_str };
                param_count += 1;
                params_buf[param_count] = .{ "sid", sid };
                param_count += 1;
            } else {
                query = try self_.buildStateSelectQuery(allocator, "AND category = {{cat:String}}", "ORDER BY updated_at DESC, id DESC");
                params_buf[param_count] = .{ "cat", cat_str };
                param_count += 1;
            }
        } else if (session_id) |sid| {
            query = try self_.buildStateSelectQuery(allocator, "AND session_id = {{sid:String}}", "ORDER BY updated_at DESC, id DESC");
            params_buf[param_count] = .{ "sid", sid };
            param_count += 1;
        } else {
            query = try self_.buildStateSelectQuery(allocator, "", "ORDER BY updated_at DESC, id DESC");
        }
        defer allocator.free(query);

        const body = try self_.executeQuery(allocator, query, params_buf[0..param_count]);
        defer allocator.free(body);
        const rows = try parseTsvRows(allocator, body);
        defer freeTsvRows(allocator, rows);

        var entries: std.ArrayList(MemoryEntry) = .empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }
        for (rows) |row| {
            try entries.append(allocator, try buildEntry(allocator, row));
        }
        return entries.toOwnedSlice(allocator);
    }

    fn implForget(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        const existing = try self_.memory().get(self_.allocator, key);
        if (existing == null) return false;
        existing.?.deinit(self_.allocator);
        try self_.emitLocalEvent(.delete_all, key, null, null, null, null);
        return true;
    }

    fn implForgetScoped(ptr: *anyopaque, key: []const u8, session_id: ?[]const u8) anyerror!bool {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        const existing = try self_.memory().getScoped(self_.allocator, key, session_id);
        if (existing == null) return false;
        existing.?.deinit(self_.allocator);
        try self_.emitLocalEvent(.delete_scoped, key, session_id, null, null, null);
        return true;
    }

    fn implListEvents(ptr: *anyopaque, allocator: std.mem.Allocator, after_sequence: u64, limit: usize) anyerror![]MemoryEvent {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        return self_.listEventsInternal(allocator, after_sequence, limit);
    }

    fn implApplyEvent(ptr: *anyopaque, input: MemoryEventInput) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.ensureProjectionUpToDate();
        if (input.origin_sequence <= try self_.getFrontier(self_.allocator, input.origin_instance_id)) return;
        try self_.recordAndProjectEvent(input);
    }

    fn implLastEventSequence(ptr: *anyopaque) anyerror!u64 {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        return self_.getLastSequence(self_.allocator);
    }

    fn implEventFeedInfo(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!MemoryEventFeedInfo {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.ensureProjectionUpToDate();
        const compacted = try self_.getCompactedThroughSequence(allocator);
        return .{
            .instance_id = try allocator.dupe(u8, self_.localInstanceId()),
            .last_sequence = try self_.getLastSequence(allocator),
            .next_local_origin_sequence = try self_.nextLocalOriginSequence(allocator),
            .supports_compaction = true,
            .storage_kind = .native,
            .compacted_through_sequence = compacted,
            .oldest_available_sequence = compacted + 1,
        };
    }

    fn implCompactEvents(ptr: *anyopaque) anyerror!u64 {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.ensureProjectionUpToDate();
        const compacted_through = try self_.getLastSequence(self_.allocator);
        const query = try std.fmt.allocPrint(self_.allocator,
            \\ALTER TABLE {s}.{s} DELETE
            \\WHERE instance_id = {{iid:String}} AND local_sequence <= {{seq:UInt64}}
        , .{ self_.db_q, self_.events_table_q });
        defer self_.allocator.free(query);
        var seq_buf: [32]u8 = undefined;
        const seq_str = try std.fmt.bufPrint(&seq_buf, "{d}", .{compacted_through});
        try self_.executeMutation(query, &.{
            .{ "iid", self_.localInstanceId() },
            .{ "seq", seq_str },
        });
        try self_.setCompactedThroughSequence(compacted_through);
        try self_.setProjectedSequence(compacted_through);
        return compacted_through;
    }

    fn implExportCheckpoint(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        return self_.exportCheckpointPayload(allocator);
    }

    fn implApplyCheckpoint(ptr: *anyopaque, payload: []const u8) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.applyCheckpointPayload(payload);
    }

    fn implCount(ptr: *anyopaque) anyerror!usize {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        try self_.ensureProjectionUpToDate();
        const query = try std.fmt.allocPrint(self_.allocator,
            \\SELECT count()
            \\FROM (
            \\    SELECT key, session_id
            \\    FROM {s}.{s}
            \\    WHERE instance_id = {{iid:String}}
            \\    GROUP BY key, session_id
            \\)
        , .{ self_.db_q, self_.table_q });
        defer self_.allocator.free(query);
        return @intCast(try self_.queryU64(self_.allocator, query, &.{.{ "iid", self_.localInstanceId() }}));
    }

    fn implHealthCheck(ptr: *anyopaque) bool {
        const self_: *Self = @ptrCast(@alignCast(ptr));
        const body = self_.executeQuery(self_.allocator, "SELECT 1", &.{}) catch return false;
        self_.allocator.free(body);
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

    // ── SessionStore vtable implementation ─────────────────────────

    fn implSessionSaveMessage(ptr: *anyopaque, session_id: []const u8, role: []const u8, content: []const u8) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const message_id = try generateId(self_.allocator);
        defer self_.allocator.free(message_id);

        const insert_query = try std.fmt.allocPrint(self_.allocator,
            \\INSERT INTO {s}.{s} (session_id, message_id, role, content, instance_id, created_at)
            \\VALUES ({{sid:String}}, {{mid:String}}, {{role:String}}, {{content:String}}, {{iid:String}}, now64(3))
        , .{ self_.db_q, self_.messages_table_q });
        defer self_.allocator.free(insert_query);

        try self_.executeStatement(insert_query, &.{
            .{ "sid", session_id },
            .{ "mid", message_id },
            .{ "role", role },
            .{ "content", content },
            .{ "iid", self_.instance_id },
        });
    }

    fn implSessionLoadMessages(ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8) anyerror![]MessageEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const query = try std.fmt.allocPrint(allocator,
            \\SELECT role, content FROM {s}.{s}
            \\WHERE session_id = {{sid:String}} AND instance_id = {{iid:String}}
            \\ORDER BY message_order ASC, message_id ASC
        , .{ self_.db_q, self_.messages_table_q });
        defer allocator.free(query);

        const body = try self_.executeQuery(allocator, query, &.{
            .{ "sid", session_id },
            .{ "iid", self_.instance_id },
        });
        defer allocator.free(body);

        const rows = try parseTsvRows(allocator, body);
        defer freeTsvRows(allocator, rows);

        var messages = try allocator.alloc(MessageEntry, rows.len);
        var filled: usize = 0;
        errdefer {
            for (messages[0..filled]) |entry| {
                allocator.free(entry.role);
                allocator.free(entry.content);
            }
            allocator.free(messages);
        }

        for (rows) |row| {
            if (row.len < 2) continue;
            messages[filled] = .{
                .role = try allocator.dupe(u8, row[0]),
                .content = try allocator.dupe(u8, row[1]),
            };
            filled += 1;
        }

        // Shrink if some rows were skipped
        if (filled < messages.len) {
            const result = try allocator.realloc(messages, filled);
            return result;
        }

        return messages;
    }

    fn implSessionClearMessages(ptr: *anyopaque, session_id: []const u8) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const query = try std.fmt.allocPrint(self_.allocator,
            \\ALTER TABLE {s}.{s} DELETE
            \\WHERE session_id = {{sid:String}} AND instance_id = {{iid:String}}
        , .{ self_.db_q, self_.messages_table_q });
        defer self_.allocator.free(query);

        try self_.executeMutation(query, &.{
            .{ "sid", session_id },
            .{ "iid", self_.instance_id },
        });

        const clear_usage = try std.fmt.allocPrint(self_.allocator,
            \\ALTER TABLE {s}.{s} DELETE
            \\WHERE session_id = {{sid:String}} AND instance_id = {{iid:String}}
        , .{ self_.db_q, self_.usage_table_q });
        defer self_.allocator.free(clear_usage);

        try self_.executeMutation(clear_usage, &.{
            .{ "sid", session_id },
            .{ "iid", self_.instance_id },
        });
    }

    fn implSessionClearAutoSaved(ptr: *anyopaque, session_id: ?[]const u8) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        if (session_id) |sid| {
            const query = try std.fmt.allocPrint(self_.allocator,
                \\ALTER TABLE {s}.{s} DELETE
                \\WHERE key LIKE 'autosave_%%' AND session_id = {{sid:String}} AND instance_id = {{iid:String}}
            , .{ self_.db_q, self_.table_q });
            defer self_.allocator.free(query);

            try self_.executeMutation(query, &.{
                .{ "sid", sid },
                .{ "iid", self_.instance_id },
            });
        } else {
            const query = try std.fmt.allocPrint(self_.allocator,
                \\ALTER TABLE {s}.{s} DELETE
                \\WHERE key LIKE 'autosave_%%' AND instance_id = {{iid:String}}
            , .{ self_.db_q, self_.table_q });
            defer self_.allocator.free(query);

            try self_.executeMutation(query, &.{
                .{ "iid", self_.instance_id },
            });
        }
    }

    fn implSessionSaveUsage(ptr: *anyopaque, session_id: []const u8, total_tokens: u64) anyerror!void {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        var tokens_buf: [20]u8 = undefined;
        const tokens_str = try std.fmt.bufPrint(&tokens_buf, "{d}", .{total_tokens});

        const query = try std.fmt.allocPrint(self_.allocator,
            \\INSERT INTO {s}.{s} (session_id, instance_id, total_tokens, updated_at)
            \\VALUES ({{sid:String}}, {{iid:String}}, {{tokens:UInt64}}, now64(3))
        , .{ self_.db_q, self_.usage_table_q });
        defer self_.allocator.free(query);

        try self_.executeStatement(query, &.{
            .{ "sid", session_id },
            .{ "iid", self_.instance_id },
            .{ "tokens", tokens_str },
        });
    }

    fn implSessionLoadUsage(ptr: *anyopaque, session_id: []const u8) anyerror!?u64 {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const query = try std.fmt.allocPrint(self_.allocator,
            \\SELECT if(count() = 0, '', toString(argMax(total_tokens, version))) FROM {s}.{s}
            \\WHERE session_id = {{sid:String}} AND instance_id = {{iid:String}}
        , .{ self_.db_q, self_.usage_table_q });
        defer self_.allocator.free(query);

        const body = try self_.executeQuery(self_.allocator, query, &.{
            .{ "sid", session_id },
            .{ "iid", self_.instance_id },
        });
        defer self_.allocator.free(body);

        const trimmed = std.mem.trim(u8, body, " \t\n\r");
        if (trimmed.len == 0) return null;
        return std.fmt.parseInt(u64, trimmed, 10) catch null;
    }

    fn implSessionCountSessions(ptr: *anyopaque) anyerror!u64 {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const query = try std.fmt.allocPrint(self_.allocator,
            \\SELECT toString(count()) FROM (
            \\    SELECT session_id
            \\    FROM {s}.{s}
            \\    WHERE instance_id = {{iid:String}} AND role != '{s}'
            \\    GROUP BY session_id
            \\)
        , .{ self_.db_q, self_.messages_table_q, root.RUNTIME_COMMAND_ROLE });
        defer self_.allocator.free(query);

        const body = try self_.executeQuery(self_.allocator, query, &.{
            .{ "iid", self_.instance_id },
        });
        defer self_.allocator.free(body);

        const trimmed = std.mem.trim(u8, body, " \t\n\r");
        if (trimmed.len == 0) return 0;
        return std.fmt.parseInt(u64, trimmed, 10) catch 0;
    }

    fn implSessionListSessions(ptr: *anyopaque, allocator: std.mem.Allocator, limit: usize, offset: usize) anyerror![]root.SessionInfo {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        var limit_buf: [20]u8 = undefined;
        const limit_str = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
        var offset_buf: [20]u8 = undefined;
        const offset_str = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});

        const query = try std.fmt.allocPrint(allocator,
            \\SELECT session_id, toString(count()), toString(min(created_at)), toString(max(created_at))
            \\FROM {s}.{s}
            \\WHERE instance_id = {{iid:String}} AND role != '{s}'
            \\GROUP BY session_id
            \\ORDER BY max(created_at) DESC
            \\LIMIT {{limit:UInt64}} OFFSET {{offset:UInt64}}
        , .{ self_.db_q, self_.messages_table_q, root.RUNTIME_COMMAND_ROLE });
        defer allocator.free(query);

        const body = try self_.executeQuery(allocator, query, &.{
            .{ "iid", self_.instance_id },
            .{ "limit", limit_str },
            .{ "offset", offset_str },
        });
        defer allocator.free(body);

        const rows = try parseTsvRows(allocator, body);
        defer freeTsvRows(allocator, rows);

        var sessions = try allocator.alloc(root.SessionInfo, rows.len);
        var filled: usize = 0;
        errdefer {
            for (sessions[0..filled]) |info| info.deinit(allocator);
            allocator.free(sessions);
        }

        for (rows) |row| {
            if (row.len < 4) continue;
            sessions[filled] = .{
                .session_id = try allocator.dupe(u8, row[0]),
                .message_count = std.fmt.parseInt(u64, row[1], 10) catch 0,
                .first_message_at = try allocator.dupe(u8, row[2]),
                .last_message_at = try allocator.dupe(u8, row[3]),
            };
            filled += 1;
        }

        if (filled < sessions.len) {
            return allocator.realloc(sessions, filled);
        }
        return sessions;
    }

    fn implSessionCountDetailedMessages(ptr: *anyopaque, session_id: []const u8) anyerror!u64 {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        const query = try std.fmt.allocPrint(self_.allocator,
            \\SELECT toString(count()) FROM {s}.{s}
            \\WHERE session_id = {{sid:String}} AND instance_id = {{iid:String}} AND role != '{s}'
        , .{ self_.db_q, self_.messages_table_q, root.RUNTIME_COMMAND_ROLE });
        defer self_.allocator.free(query);

        const body = try self_.executeQuery(self_.allocator, query, &.{
            .{ "sid", session_id },
            .{ "iid", self_.instance_id },
        });
        defer self_.allocator.free(body);

        const trimmed = std.mem.trim(u8, body, " \t\n\r");
        if (trimmed.len == 0) return 0;
        return std.fmt.parseInt(u64, trimmed, 10) catch 0;
    }

    fn implSessionLoadMessagesDetailed(ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8, limit: usize, offset: usize) anyerror![]root.DetailedMessageEntry {
        const self_: *Self = @ptrCast(@alignCast(ptr));

        var limit_buf: [20]u8 = undefined;
        const limit_str = try std.fmt.bufPrint(&limit_buf, "{d}", .{limit});
        var offset_buf: [20]u8 = undefined;
        const offset_str = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});

        const query = try std.fmt.allocPrint(allocator,
            \\SELECT role, content, toString(created_at) FROM {s}.{s}
            \\WHERE session_id = {{sid:String}} AND instance_id = {{iid:String}} AND role != '{s}'
            \\ORDER BY message_order ASC, message_id ASC
            \\LIMIT {{limit:UInt64}} OFFSET {{offset:UInt64}}
        , .{ self_.db_q, self_.messages_table_q, root.RUNTIME_COMMAND_ROLE });
        defer allocator.free(query);

        const body = try self_.executeQuery(allocator, query, &.{
            .{ "sid", session_id },
            .{ "iid", self_.instance_id },
            .{ "limit", limit_str },
            .{ "offset", offset_str },
        });
        defer allocator.free(body);

        const rows = try parseTsvRows(allocator, body);
        defer freeTsvRows(allocator, rows);

        var messages = try allocator.alloc(root.DetailedMessageEntry, rows.len);
        var filled: usize = 0;
        errdefer {
            for (messages[0..filled]) |entry| {
                allocator.free(entry.role);
                allocator.free(entry.content);
                allocator.free(entry.created_at);
            }
            allocator.free(messages);
        }

        for (rows) |row| {
            if (row.len < 3) continue;
            messages[filled] = .{
                .role = try allocator.dupe(u8, row[0]),
                .content = try allocator.dupe(u8, row[1]),
                .created_at = try allocator.dupe(u8, row[2]),
            };
            filled += 1;
        }

        if (filled < messages.len) {
            return allocator.realloc(messages, filled);
        }
        return messages;
    }

    const session_vtable = SessionStore.VTable{
        .saveMessage = &implSessionSaveMessage,
        .loadMessages = &implSessionLoadMessages,
        .clearMessages = &implSessionClearMessages,
        .clearAutoSaved = &implSessionClearAutoSaved,
        .saveUsage = &implSessionSaveUsage,
        .loadUsage = &implSessionLoadUsage,
        .countSessions = &implSessionCountSessions,
        .listSessions = &implSessionListSessions,
        .countDetailedMessages = &implSessionCountDetailedMessages,
        .loadMessagesDetailed = &implSessionLoadMessagesDetailed,
    };

    pub fn sessionStore(self: *Self) SessionStore {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &session_vtable,
        };
    }
};

fn buildQuotedSuffixTable(allocator: std.mem.Allocator, base: []const u8, suffix: []const u8) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, suffix });
    defer allocator.free(raw);
    return quoteIdentifier(allocator, raw);
}

// ── Unit Tests ────────────────────────────────────────────────────

test "validateIdentifier accepts valid names" {
    try validateIdentifier("default");
    try validateIdentifier("my_database");
    try validateIdentifier("table123");
    try validateIdentifier("a");
    try validateIdentifier("A_B_C");
}

test "validateIdentifier rejects empty" {
    try std.testing.expectError(error.EmptyIdentifier, validateIdentifier(""));
}

test "validateIdentifier rejects too long" {
    const long = "a" ** 64;
    try std.testing.expectError(error.IdentifierTooLong, validateIdentifier(long));
}

test "validateIdentifier accepts max length 63" {
    const ok = "a" ** 63;
    try validateIdentifier(ok);
}

test "validateIdentifier rejects special chars" {
    try std.testing.expectError(error.InvalidCharacter, validateIdentifier("my-database"));
    try std.testing.expectError(error.InvalidCharacter, validateIdentifier("my.database"));
    try std.testing.expectError(error.InvalidCharacter, validateIdentifier("my database"));
    try std.testing.expectError(error.InvalidCharacter, validateIdentifier("table;drop"));
    try std.testing.expectError(error.InvalidCharacter, validateIdentifier("tab`le"));
}

test "quoteIdentifier wraps in backticks" {
    const result = try quoteIdentifier(std.testing.allocator, "memories");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("`memories`", result);
}

test "escapeClickHouseString special chars" {
    const result = try escapeClickHouseString(std.testing.allocator, "it's a\nnew\\line\twith\rtab");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("it\\'s a\\nnew\\\\line\\twith\\rtab", result);
}

test "escapeClickHouseString null bytes" {
    const input = "hello\x00world";
    const result = try escapeClickHouseString(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello\\0world", result);
}

test "escapeClickHouseString no-op for safe strings" {
    const result = try escapeClickHouseString(std.testing.allocator, "hello world 123");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello world 123", result);
}

test "buildUrl http" {
    const result = try buildUrl(std.testing.allocator, "127.0.0.1", 8123, false);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("http://127.0.0.1:8123", result);
}

test "buildUrl https" {
    const result = try buildUrl(std.testing.allocator, "clickhouse.internal", 8443, true);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("https://clickhouse.internal:8443", result);
}

test "buildUrl brackets ipv6 hosts" {
    const result = try buildUrl(std.testing.allocator, "::1", 8123, false);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("http://[::1]:8123", result);
}

test "buildAuthHeader returns null for empty credentials" {
    const result = try buildAuthHeader(std.testing.allocator, "", "");
    try std.testing.expect(result == null);
}

test "buildAuthHeader returns Basic header" {
    const result = try buildAuthHeader(std.testing.allocator, "user", "pass");
    defer if (result) |r| std.testing.allocator.free(r);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.startsWith(u8, result.?, "Basic "));
}

test "getNowTimestamp returns numeric string" {
    const ts = try getNowTimestamp(std.testing.allocator);
    defer std.testing.allocator.free(ts);
    try std.testing.expect(ts.len > 0);
    for (ts) |ch| {
        try std.testing.expect(ch == '-' or std.ascii.isDigit(ch));
    }
}

test "generateId produces unique values" {
    const id1 = try generateId(std.testing.allocator);
    defer std.testing.allocator.free(id1);
    const id2 = try generateId(std.testing.allocator);
    defer std.testing.allocator.free(id2);
    try std.testing.expect(!std.mem.eql(u8, id1, id2));
}

test "urlEncode safe chars preserved" {
    const result = try urlEncode(std.testing.allocator, "hello-world_123.test~ok");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello-world_123.test~ok", result);
}

test "urlEncode special chars encoded" {
    const result = try urlEncode(std.testing.allocator, "hello world&foo=bar");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello%20world%26foo%3Dbar", result);
}

test "urlEncode percent sign" {
    const result = try urlEncode(std.testing.allocator, "100%done");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("100%25done", result);
}

test "unescapeClickHouseValue escaped sequences" {
    const result = try unescapeClickHouseValue(std.testing.allocator, "hello\\nworld\\t\\\\end\\'s\\0x");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello\nworld\t\\end's\x00x", result);
}

test "unescapeClickHouseValue plain text" {
    const result = try unescapeClickHouseValue(std.testing.allocator, "simple text");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("simple text", result);
}

test "parseTsvRows empty body" {
    const rows = try parseTsvRows(std.testing.allocator, "");
    defer freeTsvRows(std.testing.allocator, rows);
    try std.testing.expectEqual(@as(usize, 0), rows.len);
}

test "parseTsvRows single row" {
    const rows = try parseTsvRows(std.testing.allocator, "a\tb\tc");
    defer freeTsvRows(std.testing.allocator, rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(usize, 3), rows[0].len);
    try std.testing.expectEqualStrings("a", rows[0][0]);
    try std.testing.expectEqualStrings("b", rows[0][1]);
    try std.testing.expectEqualStrings("c", rows[0][2]);
}

test "parseTsvRows multiple rows" {
    const rows = try parseTsvRows(std.testing.allocator, "a\tb\nc\td\n");
    defer freeTsvRows(std.testing.allocator, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("a", rows[0][0]);
    try std.testing.expectEqualStrings("b", rows[0][1]);
    try std.testing.expectEqualStrings("c", rows[1][0]);
    try std.testing.expectEqualStrings("d", rows[1][1]);
}

test "validateTransportSecurity allows loopback plaintext" {
    try validateTransportSecurity("127.0.0.1", false);
    try validateTransportSecurity("127.0.0.2", false);
    try validateTransportSecurity("localhost", false);
    try validateTransportSecurity("::1", false);
}

test "validateTransportSecurity rejects remote plaintext" {
    try std.testing.expectError(error.InsecureTransportNotAllowed, validateTransportSecurity("clickhouse.internal", false));
    try std.testing.expectError(error.InsecureTransportNotAllowed, validateTransportSecurity("127.evil.example", false));
}

// ── Integration Tests (gated) ─────────────────────────────────────

const ClickHouseIntegrationConfig = struct {
    host: []const u8,
    port: u16,
    database: []const u8,
    table: []const u8,
    user: []const u8,
    password: []const u8,
    use_https: bool,

    fn deinit(self: ClickHouseIntegrationConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.database);
        allocator.free(self.table);
        allocator.free(self.user);
        allocator.free(self.password);
    }
};

fn isTruthy(raw: []const u8) bool {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return std.mem.eql(u8, trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "yes") or
        std.ascii.eqlIgnoreCase(trimmed, "on");
}

fn envOrDefault(allocator: std.mem.Allocator, name: []const u8, default_value: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => allocator.dupe(u8, default_value),
        else => err,
    };
}

fn loadClickHouseIntegrationConfig(allocator: std.mem.Allocator) !?ClickHouseIntegrationConfig {
    const enabled_raw = std.process.getEnvVarOwned(allocator, "NULLCLAW_TEST_CLICKHOUSE") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    defer allocator.free(enabled_raw);
    if (!isTruthy(enabled_raw)) return null;

    const host = try envOrDefault(allocator, "NULLCLAW_TEST_CLICKHOUSE_HOST", "127.0.0.1");
    errdefer allocator.free(host);
    const database = try envOrDefault(allocator, "NULLCLAW_TEST_CLICKHOUSE_DATABASE", "default");
    errdefer allocator.free(database);
    const table = try envOrDefault(allocator, "NULLCLAW_TEST_CLICKHOUSE_TABLE", "memories");
    errdefer allocator.free(table);
    const user = try envOrDefault(allocator, "NULLCLAW_TEST_CLICKHOUSE_USER", "");
    errdefer allocator.free(user);
    const password = try envOrDefault(allocator, "NULLCLAW_TEST_CLICKHOUSE_PASSWORD", "");
    errdefer allocator.free(password);

    const port_raw = std.process.getEnvVarOwned(allocator, "NULLCLAW_TEST_CLICKHOUSE_PORT") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (port_raw) |value| allocator.free(value);
    const port = if (port_raw) |value|
        try std.fmt.parseInt(u16, std.mem.trim(u8, value, " \t\r\n"), 10)
    else
        8123;

    const https_raw = std.process.getEnvVarOwned(allocator, "NULLCLAW_TEST_CLICKHOUSE_USE_HTTPS") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (https_raw) |value| allocator.free(value);
    const use_https = if (https_raw) |value| isTruthy(value) else false;

    return .{
        .host = host,
        .port = port,
        .database = database,
        .table = table,
        .user = user,
        .password = password,
        .use_https = use_https,
    };
}

test "integration: clickhouse store and get" {
    if (!build_options.enable_memory_clickhouse) return;
    const integration_cfg = (try loadClickHouseIntegrationConfig(std.testing.allocator)) orelse return;
    defer integration_cfg.deinit(std.testing.allocator);

    const instance_id = try generateId(std.testing.allocator);
    defer std.testing.allocator.free(instance_id);

    var mem = try ClickHouseMemoryImpl.init(std.testing.allocator, .{
        .host = integration_cfg.host,
        .port = integration_cfg.port,
        .database = integration_cfg.database,
        .table = integration_cfg.table,
        .user = integration_cfg.user,
        .password = integration_cfg.password,
        .use_https = integration_cfg.use_https,
        .instance_id = instance_id,
    });
    defer mem.deinit();

    const m = mem.memory();

    try m.store("test-ch-key", "hello clickhouse", .core, null);

    const entry = try m.get(std.testing.allocator, "test-ch-key") orelse
        return error.TestUnexpectedResult;
    defer entry.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("test-ch-key", entry.key);
    try std.testing.expectEqualStrings("hello clickhouse", entry.content);
    try std.testing.expect(entry.category.eql(.core));
}

test "integration: clickhouse count" {
    if (!build_options.enable_memory_clickhouse) return;
    const integration_cfg = (try loadClickHouseIntegrationConfig(std.testing.allocator)) orelse return;
    defer integration_cfg.deinit(std.testing.allocator);

    const instance_id = try generateId(std.testing.allocator);
    defer std.testing.allocator.free(instance_id);

    var mem = try ClickHouseMemoryImpl.init(std.testing.allocator, .{
        .host = integration_cfg.host,
        .port = integration_cfg.port,
        .database = integration_cfg.database,
        .table = integration_cfg.table,
        .user = integration_cfg.user,
        .password = integration_cfg.password,
        .use_https = integration_cfg.use_https,
        .instance_id = instance_id,
    });
    defer mem.deinit();

    const m = mem.memory();

    try m.store("count-a", "aaa", .core, null);
    try m.store("count-b", "bbb", .daily, null);

    const n = try m.count();
    try std.testing.expect(n >= 2);
}

test "integration: clickhouse recall" {
    if (!build_options.enable_memory_clickhouse) return;
    const integration_cfg = (try loadClickHouseIntegrationConfig(std.testing.allocator)) orelse return;
    defer integration_cfg.deinit(std.testing.allocator);

    const instance_id = try generateId(std.testing.allocator);
    defer std.testing.allocator.free(instance_id);

    var mem = try ClickHouseMemoryImpl.init(std.testing.allocator, .{
        .host = integration_cfg.host,
        .port = integration_cfg.port,
        .database = integration_cfg.database,
        .table = integration_cfg.table,
        .user = integration_cfg.user,
        .password = integration_cfg.password,
        .use_https = integration_cfg.use_https,
        .instance_id = instance_id,
    });
    defer mem.deinit();

    const m = mem.memory();

    try m.store("recall-1", "the quick brown fox", .core, null);
    try m.store("recall-2", "lazy dog sleeps", .core, null);

    const results = try m.recall(std.testing.allocator, "brown fox", 10, null);
    defer root.freeEntries(std.testing.allocator, results);

    try std.testing.expect(results.len >= 1);
    try std.testing.expectEqualStrings("the quick brown fox", results[0].content);
}

test "integration: clickhouse forget" {
    if (!build_options.enable_memory_clickhouse) return;
    const integration_cfg = (try loadClickHouseIntegrationConfig(std.testing.allocator)) orelse return;
    defer integration_cfg.deinit(std.testing.allocator);

    const instance_id = try generateId(std.testing.allocator);
    defer std.testing.allocator.free(instance_id);

    var mem = try ClickHouseMemoryImpl.init(std.testing.allocator, .{
        .host = integration_cfg.host,
        .port = integration_cfg.port,
        .database = integration_cfg.database,
        .table = integration_cfg.table,
        .user = integration_cfg.user,
        .password = integration_cfg.password,
        .use_https = integration_cfg.use_https,
        .instance_id = instance_id,
    });
    defer mem.deinit();

    const m = mem.memory();

    try m.store("forget-me", "temp data", .conversation, null);
    const ok = try m.forget("forget-me");
    try std.testing.expect(ok);

    const entry = try m.get(std.testing.allocator, "forget-me");
    try std.testing.expect(entry == null);
}

test "integration: clickhouse native feed roundtrip" {
    if (!build_options.enable_memory_clickhouse) return;
    const integration_cfg = (try loadClickHouseIntegrationConfig(std.testing.allocator)) orelse return;
    defer integration_cfg.deinit(std.testing.allocator);

    const instance_seed = try generateId(std.testing.allocator);
    defer std.testing.allocator.free(instance_seed);
    const first_id = try std.fmt.allocPrint(std.testing.allocator, "agent_a_{s}", .{instance_seed});
    defer std.testing.allocator.free(first_id);
    const second_id = try std.fmt.allocPrint(std.testing.allocator, "agent_b_{s}", .{instance_seed});
    defer std.testing.allocator.free(second_id);

    var first = try ClickHouseMemoryImpl.init(std.testing.allocator, .{
        .host = integration_cfg.host,
        .port = integration_cfg.port,
        .database = integration_cfg.database,
        .table = integration_cfg.table,
        .user = integration_cfg.user,
        .password = integration_cfg.password,
        .use_https = integration_cfg.use_https,
        .instance_id = first_id,
    });
    defer first.deinit();

    var second = try ClickHouseMemoryImpl.init(std.testing.allocator, .{
        .host = integration_cfg.host,
        .port = integration_cfg.port,
        .database = integration_cfg.database,
        .table = integration_cfg.table,
        .user = integration_cfg.user,
        .password = integration_cfg.password,
        .use_https = integration_cfg.use_https,
        .instance_id = second_id,
    });
    defer second.deinit();

    const first_mem = first.memory();
    const second_mem = second.memory();

    try first_mem.store("prefs/theme", "gruvbox", .core, "sess-a");

    var info = try first_mem.eventFeedInfo(std.testing.allocator);
    defer info.deinit(std.testing.allocator);
    try std.testing.expectEqual(root.MemoryEventFeedStorage.native, info.storage_kind);
    try std.testing.expect(info.last_sequence > 0);

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
    try std.testing.expectEqualStrings("gruvbox", restored.content);
}

test "integration: clickhouse feed compact and checkpoint restore" {
    if (!build_options.enable_memory_clickhouse) return;
    const integration_cfg = (try loadClickHouseIntegrationConfig(std.testing.allocator)) orelse return;
    defer integration_cfg.deinit(std.testing.allocator);

    const instance_seed = try generateId(std.testing.allocator);
    defer std.testing.allocator.free(instance_seed);
    const source_id = try std.fmt.allocPrint(std.testing.allocator, "agent_src_{s}", .{instance_seed});
    defer std.testing.allocator.free(source_id);
    const replica_id = try std.fmt.allocPrint(std.testing.allocator, "agent_replica_{s}", .{instance_seed});
    defer std.testing.allocator.free(replica_id);

    var source = try ClickHouseMemoryImpl.init(std.testing.allocator, .{
        .host = integration_cfg.host,
        .port = integration_cfg.port,
        .database = integration_cfg.database,
        .table = integration_cfg.table,
        .user = integration_cfg.user,
        .password = integration_cfg.password,
        .use_https = integration_cfg.use_https,
        .instance_id = source_id,
    });
    defer source.deinit();

    const source_mem = source.memory();
    try source_mem.store("prefs/lang", "zig", .core, null);
    try source_mem.store("prefs/editor", "zed", .core, "sess-b");

    const checkpoint = try source_mem.exportCheckpoint(std.testing.allocator);
    defer std.testing.allocator.free(checkpoint);

    const compacted = try source_mem.compactEvents();
    try std.testing.expect(compacted > 0);
    try std.testing.expectError(error.CursorExpired, source_mem.listEvents(std.testing.allocator, 0, 10));

    var replica = try ClickHouseMemoryImpl.init(std.testing.allocator, .{
        .host = integration_cfg.host,
        .port = integration_cfg.port,
        .database = integration_cfg.database,
        .table = integration_cfg.table,
        .user = integration_cfg.user,
        .password = integration_cfg.password,
        .use_https = integration_cfg.use_https,
        .instance_id = replica_id,
    });
    defer replica.deinit();

    const replica_mem = replica.memory();
    try replica_mem.applyCheckpoint(checkpoint);

    const source_still_present = try source_mem.get(std.testing.allocator, "prefs/lang") orelse
        return error.TestUnexpectedResult;
    defer source_still_present.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zig", source_still_present.content);

    const global_entry = try replica_mem.get(std.testing.allocator, "prefs/lang") orelse
        return error.TestUnexpectedResult;
    defer global_entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zig", global_entry.content);

    const scoped_entry = try replica_mem.getScoped(std.testing.allocator, "prefs/editor", "sess-b") orelse
        return error.TestUnexpectedResult;
    defer scoped_entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("zed", scoped_entry.content);

    var restored_info = try replica_mem.eventFeedInfo(std.testing.allocator);
    defer restored_info.deinit(std.testing.allocator);
    try std.testing.expect(restored_info.next_local_origin_sequence >= 2);
    try std.testing.expect(restored_info.last_sequence >= 2);
}

test "integration: clickhouse invalid checkpoint does not clear existing instance state" {
    if (!build_options.enable_memory_clickhouse) return;
    const integration_cfg = (try loadClickHouseIntegrationConfig(std.testing.allocator)) orelse return;
    defer integration_cfg.deinit(std.testing.allocator);

    const instance_id = try generateId(std.testing.allocator);
    defer std.testing.allocator.free(instance_id);

    var mem = try ClickHouseMemoryImpl.init(std.testing.allocator, .{
        .host = integration_cfg.host,
        .port = integration_cfg.port,
        .database = integration_cfg.database,
        .table = integration_cfg.table,
        .user = integration_cfg.user,
        .password = integration_cfg.password,
        .use_https = integration_cfg.use_https,
        .instance_id = instance_id,
    });
    defer mem.deinit();

    const memory = mem.memory();
    try memory.store("prefs/keep", "still-here", .core, null);

    const invalid_checkpoint =
        \\{"kind":"meta","schema_version":2,"last_sequence":1,"compacted_through_sequence":1}
        \\{"kind":"state","key":"prefs/keep","session_id":null,"category":"core","value_kind":null,"content":"wrong","timestamp_ms":1,"origin_instance_id":"remote","origin_sequence":1}
        \\
    ;

    try std.testing.expectError(error.InvalidEvent, memory.applyCheckpoint(invalid_checkpoint));

    const entry = try memory.get(std.testing.allocator, "prefs/keep") orelse
        return error.TestUnexpectedResult;
    defer entry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("still-here", entry.content);
}

test "integration: clickhouse feed metadata is monotonic" {
    if (!build_options.enable_memory_clickhouse) return;
    const integration_cfg = (try loadClickHouseIntegrationConfig(std.testing.allocator)) orelse return;
    defer integration_cfg.deinit(std.testing.allocator);

    const instance_id = try generateId(std.testing.allocator);
    defer std.testing.allocator.free(instance_id);

    var mem = try ClickHouseMemoryImpl.init(std.testing.allocator, .{
        .host = integration_cfg.host,
        .port = integration_cfg.port,
        .database = integration_cfg.database,
        .table = integration_cfg.table,
        .user = integration_cfg.user,
        .password = integration_cfg.password,
        .use_https = integration_cfg.use_https,
        .instance_id = instance_id,
    });
    defer mem.deinit();

    try mem.setMetaValue("last_sequence", "10");
    try mem.setMetaValue("last_sequence", "3");
    try std.testing.expectEqual(@as(u64, 10), try mem.getLastSequence(std.testing.allocator));

    const insert_frontier = try std.fmt.allocPrint(std.testing.allocator,
        \\INSERT INTO {s}.{s} (instance_id, origin_instance_id, last_origin_sequence)
        \\VALUES ({{iid:String}}, {{origin:String}}, {{seq:UInt64}})
    , .{ mem.db_q, mem.frontiers_table_q });
    defer std.testing.allocator.free(insert_frontier);
    try mem.executeStatement(insert_frontier, &.{
        .{ "iid", mem.localInstanceId() },
        .{ "origin", "remote-agent" },
        .{ "seq", "10" },
    });
    try mem.executeStatement(insert_frontier, &.{
        .{ "iid", mem.localInstanceId() },
        .{ "origin", "remote-agent" },
        .{ "seq", "3" },
    });
    try std.testing.expectEqual(@as(u64, 10), try mem.getFrontier(std.testing.allocator, "remote-agent"));

    const insert_tombstone = try std.fmt.allocPrint(std.testing.allocator,
        \\INSERT INTO {s}.{s} (instance_id, key, scope, session_key, session_id, timestamp_ms, origin_instance_id, origin_sequence)
        \\VALUES ({{iid:String}}, {{key:String}}, {{scope:String}}, {{session_key:String}}, {{session_id:String}}, {{timestamp_ms:Int64}}, {{origin_instance_id:String}}, {{origin_sequence:UInt64}})
    , .{ mem.db_q, mem.tombstones_table_q });
    defer std.testing.allocator.free(insert_tombstone);
    try mem.executeStatement(insert_tombstone, &.{
        .{ "iid", mem.localInstanceId() },
        .{ "key", "prefs/theme" },
        .{ "scope", "scoped" },
        .{ "session_key", "sess-x" },
        .{ "session_id", "sess-x" },
        .{ "timestamp_ms", "200" },
        .{ "origin_instance_id", "agent-a" },
        .{ "origin_sequence", "9" },
    });
    try mem.executeStatement(insert_tombstone, &.{
        .{ "iid", mem.localInstanceId() },
        .{ "key", "prefs/theme" },
        .{ "scope", "scoped" },
        .{ "session_key", "sess-x" },
        .{ "session_id", "sess-x" },
        .{ "timestamp_ms", "100" },
        .{ "origin_instance_id", "agent-z" },
        .{ "origin_sequence", "99" },
    });

    const tombstone = try mem.getTombstoneMeta(std.testing.allocator, "prefs/theme", "scoped", "sess-x") orelse
        return error.TestUnexpectedResult;
    defer tombstone.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 200), tombstone.timestamp_ms);
    try std.testing.expectEqualStrings("agent-a", tombstone.origin_instance_id);
    try std.testing.expectEqual(@as(u64, 9), tombstone.origin_sequence);
}

test "integration: clickhouse health check" {
    if (!build_options.enable_memory_clickhouse) return;
    const integration_cfg = (try loadClickHouseIntegrationConfig(std.testing.allocator)) orelse return;
    defer integration_cfg.deinit(std.testing.allocator);

    const instance_id = try generateId(std.testing.allocator);
    defer std.testing.allocator.free(instance_id);

    var mem = try ClickHouseMemoryImpl.init(std.testing.allocator, .{
        .host = integration_cfg.host,
        .port = integration_cfg.port,
        .database = integration_cfg.database,
        .table = integration_cfg.table,
        .user = integration_cfg.user,
        .password = integration_cfg.password,
        .use_https = integration_cfg.use_https,
        .instance_id = instance_id,
    });
    defer mem.deinit();

    try std.testing.expect(mem.memory().healthCheck());
}

test "integration: clickhouse name" {
    if (!build_options.enable_memory_clickhouse) return;
    const integration_cfg = (try loadClickHouseIntegrationConfig(std.testing.allocator)) orelse return;
    defer integration_cfg.deinit(std.testing.allocator);

    const instance_id = try generateId(std.testing.allocator);
    defer std.testing.allocator.free(instance_id);

    var mem = try ClickHouseMemoryImpl.init(std.testing.allocator, .{
        .host = integration_cfg.host,
        .port = integration_cfg.port,
        .database = integration_cfg.database,
        .table = integration_cfg.table,
        .user = integration_cfg.user,
        .password = integration_cfg.password,
        .use_https = integration_cfg.use_https,
        .instance_id = instance_id,
    });
    defer mem.deinit();

    try std.testing.expectEqualStrings("clickhouse", mem.memory().name());
}

test "clickhouse sorting key must include session_id" {
    try std.testing.expect(memorySortingKeySupportsSessions("instance_id, key, session_id"));
    try std.testing.expect(memorySortingKeySupportsSessions("(instance_id, key, session_id)"));
    try std.testing.expect(!memorySortingKeySupportsSessions("instance_id, key"));
}
