# Decoupling Cross-Subsystem Entanglement: Message Passing Analysis

> Evaluated against actual coupling points in nullclaw
> Date: 2026-04-08

---

## TL;DR: The coupling is data format translation, not message routing. A bus already exists. Go-style channels would NOT solve this problem.

---

## 1. The Actual Coupling (Not What You Think)

### What We Found

The ONLY cross-subsystem coupling violation (besides expected agent → everything) is:

```zig
// src/cron.zig:10-11
const telegram = @import("channels/telegram.zig");
const signal = @import("channels/signal.zig");
```

### What It's Used For (Lines 118-151)

```zig
pub fn enrichDeliveryRouting(delivery: DeliveryConfig) DeliveryConfig {
    var enriched = delivery;
    const channel = enriched.channel orelse return enriched;
    const target = enriched.to orelse return enriched;

    if (std.mem.eql(u8, channel, "telegram")) {
        const base_chat_id = telegram.targetChatId(target);      // ← extracts chat ID from "group:123"
        if (enriched.peer_id == null) enriched.peer_id = base_chat_id;
        enriched.peer_kind = if (telegram.targetThreadId(target) != null) .group else .direct;
        return enriched;
    }

    if (std.mem.eql(u8, channel, "signal")) {
        enriched.peer_id = signal.signalGroupPeerId(target);     // ← extracts signal peer ID
        enriched.peer_kind = if (std.mem.startsWith(u8, target, signal.GROUP_TARGET_PREFIX))
            .group else .direct;
        return enriched;
    }
    // ...
}
```

### What This IS:
**Data format translation** — converting a generic target string (like `"group:123"`) into channel-specific address formats (Telegram's `-1001234567890`, Signal's `+1234567890`).

### What This is NOT:
- **NOT** message routing (cron doesn't send messages through channels)
- **NOT** event dispatch (cron doesn't fire events that channels listen to)
- **NOT** control flow coupling (cron doesn't call channel methods to start/stop)

---

## 2. The Bus Already Exists

`src/bus.zig` is a fully implemented event bus:

```zig
//! Event Bus — inter-component message bus for nullClaw.
//! Two blocking queues (inbound: channels→agent, outbound: agent→channels)
//! on a ring buffer with Mutex+Condition.
//! Foundation for Session Manager, Message tool, Heartbeat execution,
//! Cron dispatch, USB hotplug.

pub const InboundMessage = struct {
    channel: []const u8,      // "telegram", "discord", "webhook", "system"
    sender_id: []const u8,
    chat_id: []const u8,
    content: []const u8,
    session_key: []const u8,
    media: []const []const u8 = &.{},
    metadata_json: ?[]const u8 = null,
};

pub const OutboundMessage = struct {
    channel: []const u8,
    account_id: ?[]const u8 = null,
    chat_id: []const u8,
    content: []const u8,
    media: []const []const u8 = &.{},
    choices: []const outbound.Choice = &.{},
    stage: streaming.OutboundStage = .final,
};
```

**The bus already handles message passing between channels and the agent.** Cron already uses `bus.OutboundMessage` for job result delivery (line 853: "If `out_bus` is provided, job results are delivered to channels per delivery config").

**The bus does NOT handle address format translation.** That's what `enrichDeliveryRouting()` does, and that's why it imports telegram.zig and signal.zig.

---

## 3. Why Go-Style Channels Wouldn't Help

### The Problem Go Channels Solve:
**Coordination between concurrent goroutines** — passing data from producer to consumer without shared state.

### The Problem nullclaw Has:
**Address format translation** — converting `"group:123"` into Telegram's `-1001234567890`.

These are **completely different problems**. Go channels would add indirection without solving the actual coupling.

### What Go-Style Channels Would Look Like in Zig:
```zig
// Hypothetical: cron publishes to a channel
const notification_bus = bus.Channel(DeliveryEvent).init(allocator);

// Cron publishes
notification_bus.publish(.{
    .channel = "telegram",
    .target = "group:123",
    .content = "Job completed",
});

// Telegram subscribes
telegram.subscribe(notification_bus, |event| {
    const chat_id = telegram.targetChatId(event.target);  // ← STILL needs telegram.zig!
    telegram.sendMessage(chat_id, event.content);
});
```

**The coupling just moved** — now the Telegram subscriber needs to know its own address format. The bus didn't decouple anything; it just added a layer of indirection.

---

## 4. The Real Solutions (Ranked by Pragmatism)

### Option A: Registry Pattern (Best Tradeoff)

Each channel registers its address parser with a central registry:

```zig
// src/channel_address.zig (new module)
pub const AddressParser = struct {
    name: []const u8,
    parseTarget: *const fn (target: []const u8) DeliveryRouting,
};

var registry: std.StaticStringMap(AddressParser) = undefined;

pub fn registerParser(parser: AddressParser) void {
    // Register at startup
}

pub fn enrichDeliveryRouting(channel: []const u8, target: []const u8) ?DeliveryRouting {
    if (registry.get(channel)) |parser| {
        return parser.parseTarget(target);
    }
    return null;
}
```

**Pros:**
- Cron no longer imports telegram.zig or signal.zig
- New channels register their own parser — zero cron changes
- Follows existing factory pattern (ProviderHolder, ChannelRegistry)
- ~50 lines of new code

**Cons:**
- Still requires each channel to export its parser function
- Registry initialization order matters (startup complexity)
- Adds one more abstraction layer

**Binary size impact**: ~2-3 KB (StaticStringMap + struct definitions)

---

### Option B: Protocol Buffers / Universal Address Format

Define a universal address format that all channels conform to:

```zig
// src/channel_address.zig
pub const ChannelAddress = struct {
    channel: []const u8,
    peer_kind: ChatType,
    peer_id: []const u8,
    thread_id: ?[]const u8 = null,

    /// Parse from a generic string like "group:123"
    pub fn parse(allocator: Allocator, raw: []const u8) !ChannelAddress {
        // Universal parsing logic
    }
};
```

**Pros:**
- Single parsing module, no channel imports
- Universal format works for all channels
- Easy to test (pure functions)

**Cons:**
- Requires defining a universal address grammar
- May not cover all channel-specific quirks
- Breaking change for existing config formats

**Binary size impact**: ~5-8 KB (universal parser + error handling)

---

### Option C: Leave It As-Is (Most Pragmatic)

**The coupling is 2 imports, 30 lines of code, and unlikely to change.**

- How often do new channels get added? ~1-2 per year
- How often does address format change? Never (Telegram/Signal formats are stable)
- What's the cost of the coupling? Zero runtime cost, minimal maintenance
- What's the cost of decoupling? 50-100 lines of new code + registry complexity

**The Pragmatic Programmer principle**: "Don't introduce unnecessary complexity."

---

## 5. Decision Matrix

| Criterion | Option A: Registry | Option B: Universal Format | Option C: Leave As-Is |
|-----------|-------------------|---------------------------|----------------------|
| **Decouples cron from channels** | ✅ Yes | ✅ Yes | ❌ No |
| **Extensible (new channels)** | ✅ Zero cron changes | ✅ Zero cron changes | ❌ Must update cron |
| **Binary size impact** | +2-3 KB | +5-8 KB | 0 |
| **Code complexity** | Medium (registry) | High (universal parser) | Low (2 imports) |
| **Test complexity** | Medium (mock registry) | High (test all formats) | Low (test 2 channels) |
| **Maintenance burden** | Medium (registry init) | High (format compatibility) | Low |
| **Time to implement** | 2-3 hours | 4-6 hours | 0 |
| **Pragmatic score** | 7/10 | 5/10 | 9/10 |

---

## 6. The Verdict

**Don't decouple this.** The coupling is:
- **Tiny**: 2 imports, 30 lines
- **Stable**: Telegram/Signal address formats don't change
- **Rarely touched**: New channels are added ~1-2 per year
- **Zero runtime cost**: No indirection, no message copying, no queue management

The bus already exists and handles message passing. The "coupling" is actually **address format translation** — a different problem entirely.

**If you MUST decouple** (for architectural purity), use Option A (Registry Pattern). It follows the existing factory pattern, adds minimal complexity, and costs ~2-3 KB of binary size.

**But the pragmatic answer**: Leave it. The coupling is intentional, documented, and unlikely to cause problems. The cost of decoupling exceeds the benefit by at least an order of magnitude.

---

## 7. What About Other "Entanglements"?

### Cron → Channels (the one we analyzed)
**Status**: Address format translation, not message routing. Leave as-is.

### Agent → Everything (expected)
**Status**: Agent is the orchestrator. This is by design.

### Gateway → Everything (expected)
**Status**: Gateway is the HTTP entry point. This is by design.

### Tools → Memory/Bootstrap (expected)
**Status**: Tools need memory access and bootstrap data. This is by design.

### Channels → http_util/json_util (infrastructure)
**Status**: Shared utilities, not domain coupling. This is by design.

**There are no actual entanglements to fix.** The architecture is clean. The only "violation" is address format translation, which is a data problem, not a coupling problem.
