const root = @import("root.zig");

pub const ApplyResult = root.MemoryApplyResult;

pub const MemoryFeed = struct {
    runtime: *root.MemoryRuntime,

    pub fn init(runtime: *root.MemoryRuntime) MemoryFeed {
        return .{ .runtime = runtime };
    }

    pub fn status(self: *const MemoryFeed) !root.MemoryEventFeedInfo {
        return self.runtime.feedStatus();
    }

    pub fn listEvents(
        self: *const MemoryFeed,
        allocator: @import("std").mem.Allocator,
        after_sequence: ?u64,
        limit: usize,
    ) ![]root.MemoryEvent {
        return self.runtime.feedListEvents(allocator, after_sequence, limit);
    }

    pub fn apply(self: *MemoryFeed, event: root.MemoryEventInput) !ApplyResult {
        return self.runtime.feedApply(event);
    }

    pub fn compact(self: *MemoryFeed) !usize {
        return self.runtime.feedCompact();
    }

    pub fn rebuild(self: *MemoryFeed) !void {
        return self.runtime.feedRebuild();
    }
};
