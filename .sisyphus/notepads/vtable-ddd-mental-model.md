# VTable Architecture ↔ Strategic DDD Mental Model

> Built from nullclaw source code analysis (Zig 0.15.2)
> Updated: 2026-04-08

---

## 1. The Core Insight: VTables ARE Anti-Corruption Layers

In DDD, an **Anti-Corruption Layer (ACL)** is a translation layer that protects one bounded context from the model of another. In Zig's vtable pattern, the **VTable struct IS the ACL** — it defines exactly what the calling context is allowed to know and do.

```
┌─────────────────────────────────────────────────────────────┐
│                    Calling Context                           │
│              (agent.zig — the orchestration loop)            │
│                                                              │
│  const provider: Provider = ...                              │
│  const response = try provider.chat(allocator, req, ...);    │
│                                                              │
│  ↑ The caller knows ONLY:                                    │
│    - Provider has chat(), chatWithSystem(), etc.             │
│    - Returns ChatResponse                                    │
│    - Nothing about HTTP, API keys, JSON parsing, or models   │
└──────────────────────────┬──────────────────────────────────┘
                           │
                    Provider.VTable  ←── THE ANTI-CORRUPTION LAYER
                           │         Defines the Ubiquitous Language
                           │         of the AI Model Provider BC
                           │
┌──────────────────────────┴──────────────────────────────────┐
│              Implementation Context                          │
│              (src/providers/openai.zig)                      │
│                                                              │
│  OpenAIProvider {                                            │
│    base_url: []const u8,         ← infrastructure details    │
│    api_key: ?[]const u8,         ← secrets                   │
│    http_timeout: u64,            ← operational config        │
│    ...                             ← ALL hidden from caller  │
│  }                                                           │
│                                                              │
│  fn chatImpl(self: *OpenAIProvider, ...) {                   │
│    // Real HTTP calls, JSON parsing, error handling          │
│    // ALL of this is infrastructure                          │
│  }                                                           │
└─────────────────────────────────────────────────────────────┘
```

**The VTable is the boundary contract.** The caller interacts with `Provider.chat()`, not `openai.makeHttpRequest()`. The implementation is free to change its internals without affecting any caller.

---

## 2. Each Subsystem IS a Bounded Context

### The Mapping

| DDD Concept | nullclaw VTable Equivalent | Example |
|-------------|---------------------------|---------|
| **Bounded Context** | Subsystem directory (`providers/`, `channels/`, `tools/`) | `src/providers/` = AI Model Provider Context |
| **Ubiquitous Language** | Domain types in `root.zig` (`ChatRequest`, `ChatResponse`, `ChatMessage`) | The shared vocabulary of the Provider BC |
| **Interface/ACL** | `VTable` struct (`Provider.VTable`, `Channel.VTable`) | The contract — what operations are available |
| **Strategy Implementation** | Concrete struct (`OpenAIProvider`, `TelegramChannel`) | One way to fulfill the contract |
| **Factory** | Registration in `root.zig` or `factory.zig` | Wires config → implementation |
| **Aggregate Root** | `Runtime`, `Session` — coordinates VTable implementations | `src/agent/root.zig` orchestrates provider+channel+tool |
| **Domain Event** | `ToolResult`, `ChatResponse`, observer events | Data that crosses BC boundaries |
| **Context Map Relationship** | Dependency direction between subsystems | `agent/` → `providers/` (upstream→downstream) |
| **Conformist** | Shared types (`ChatRequest`, `ChannelMessage`) | Downstream BCs conform to upstream types |
| **Open Host Service** | Optional vtable methods (`chat_with_tools`, `stream_chat`) | Protocol that can be extended |
| **Published Language** | `ToolSpec` (JSON schema for LLM function calling) | Standardized interface for external consumers |

### Evidence from Source

**Provider VTable** (line 351-401 in `src/providers/root.zig`):
```zig
pub const VTable = struct {
    // Core operations — every provider MUST implement these
    chatWithSystem: *const fn (...) anyerror![]const u8,
    chat: *const fn (...) anyerror!ChatResponse,
    supportsNativeTools: *const fn (...) bool,
    getName: *const fn (...) []const u8,
    deinit: *const fn (...) void,

    // Optional capabilities — Open Host Service pattern
    warmup: ?*const fn (...) void = null,                        // pre-warm connection
    chat_with_tools: ?*const fn (...) anyerror!ChatResponse = null, // native function calling
    supports_streaming: ?*const fn (...) bool = null,             // SSE support
    supports_vision: ?*const fn (...) bool = null,                // multimodal
    supports_vision_for_model: ?*const fn (...) bool = null,      // model-specific vision
    stream_chat: ?*const fn (...) anyerror!StreamChatResult = null, // streaming chat
};
```

**Channel VTable** (line 137-186 in `src/channels/root.zig`):
```zig
pub const VTable = struct {
    // Core operations
    start: *const fn (...) anyerror!void,
    stop: *const fn (...) void,
    send: *const fn (...) anyerror!void,
    name: *const fn (...) []const u8,
    healthCheck: *const fn (...) bool,

    // Optional capabilities — extending the protocol
    sendEvent: ?*const fn (...) anyerror!void = null,         // staged outbound (streaming)
    sendRich: ?*const fn (...) anyerror!void = null,           // structured payloads
    sendTracked: ?*const fn (...) anyerror!?MessageRef = null, // returns message ID
    startTyping: *const fn (...) anyerror!void = &defaultStartTyping,
    stopTyping: *const fn (...) anyerror!void = &defaultStopTyping,
    editMessage: ?*const fn (...) anyerror!void = null,
    deleteMessage: ?*const fn (...) anyerror!void = null,
    setReaction: *const fn (...) anyerror!void = &defaultSetReaction,
    markRead: *const fn (...) anyerror!void = &defaultMarkRead,
    supportsStreamingOutbound: *const fn (...) bool = &defaultSupportsStreamingOutbound,
    supportsTrackedDrafts: *const fn (...) bool = &defaultSupportsTrackedDrafts,
};
```

**Tool VTable** (line 171-177 in `src/tools/root.zig`):
```zig
pub const VTable = struct {
    execute: *const fn (...) anyerror!ToolResult,
    name: *const fn (...) []const u8,
    description: *const fn (...) []const u8,
    parameters_json: *const fn (...) []const u8,
    deinit: ?*const fn (...) void = null,  // optional cleanup
};
```

---

## 3. The Dependency Direction = Upstream/Downstream

From reading imports in `root.zig` files:

```
                    ┌──────────────┐
                    │   config.zig  │  ← Configuration BC
                    │   (core)      │
                    └──────┬───────┘
                           │
                    ┌──────▼───────┐
                    │  agent/root  │  ← Application BC (orchestration)
                    │    .zig      │
                    └──┬──┬──┬──┬─┘
                       │  │  │  │
            ┌──────────┘  │  │  └──────────┐
            ▼             ▼  ▼             ▼
     ┌──────────┐  ┌──────┐  ┌──────┐  ┌──────────┐
     │providers/│  │channels│ │tools/│  │ memory/  │
     │          │  │/       │ │      │  │          │
     │OpenAI    │  │Telegram│ │shell │  │sqlite    │
     │Anthropic │  │Discord │ │file  │  │markdown  │
     │Ollama    │  │Slack   │ │git   │  │hybrid    │
     └──────────┘  └──────┘  └──────┘  └──────────┘
         │              │         │          │
         ▼              ▼         ▼          ▼
     ┌──────────────────────────────────────────────┐
     │           Infrastructure Layer               │
     │  http_util.zig, json_util.zig, security/     │
     └──────────────────────────────────────────────┘
```

**Key DDD interpretation:**
- `config.zig` = **Shared Kernel** — everyone depends on it, it defines the configuration types
- `agent/root.zig` = **Application Layer** — orchestrates domain services
- `providers/`, `channels/`, `tools/`, `memory/` = **Domain Bounded Contexts** — each implements a specific capability
- `http_util`, `json_util`, `security/` = **Infrastructure** — shared utilities

**The critical rule (from AGENTS.md §6.2):**
> "Keep dependency direction inward to contracts: concrete implementations depend on vtable/config/util, not on each other."

This is DDD's **Dependency Inversion** — domain interfaces (VTables) are owned by the calling context, not the implementation. The implementation depends on the interface, not vice versa.

---

## 4. Optional VTable Methods = Capability Evolution

The pattern of `?*const fn` for optional methods is a form of **capability negotiation**:

```zig
// The caller checks capability before using it:
if (provider.supportsStreaming()) {
    // Use streaming path
} else {
    // Fall back to blocking chat
}
```

This maps to DDD's **Open Host Service** pattern — the protocol can be extended without breaking existing implementations. New providers can implement `stream_chat`, old ones gracefully fall back.

**Key insight**: The VTable defines the **maximum capability surface**. Each implementation chooses which capabilities to implement. The caller adapts to what's available.

---

## 5. Factory Pattern = Context Selection at Runtime

From `src/tools/root.zig` `allTools()` (line 308-568):

```zig
const st = try allocator.create(shell.ShellTool);
st.* = .{
    .workspace_dir = workspace_dir,
    .allowed_paths = opts.allowed_paths,
    .timeout_ns = tc.shell_timeout_secs * std.time.ns_per_s,
    // ... config-driven initialization
};
try list.append(allocator, st.tool());  // ← st.tool() returns Tool{.ptr, .vtable}
```

This is DDD's **Context Map** in action:
- Config says which providers/channels/tools to activate
- Factory creates the right implementation
- Caller only sees the VTable interface
- Changing `config.json` provider key = switching context, zero code changes

---

## 6. The VTable Ownership Rule = Aggregate Boundary

From AGENTS.md §2.1:
> "Callers must OWN the implementing struct (local var or heap-alloc). Never return a vtable interface pointing to a temporary — the pointer will dangle."

This maps to DDD's **Aggregate Root** concept:
- The caller owns the lifetime of the implementation
- The VTable is a reference, not a value
- Lifetime management is explicit (no garbage collection)
- The `deinit` method is the aggregate's cleanup

---

## 7. Cross-Subsystem Dependencies (The Forbidden Zone)

From `src/tools/root.zig` imports:
```zig
const memory_mod = @import("../memory/root.zig");    // ← Tools depends on Memory
const bootstrap_mod = @import("../bootstrap/root.zig"); // ← Tools depends on Bootstrap
const mcp_mod = @import("../mcp.zig");               // ← Tools depends on MCP
const SandboxBackend = @import("../security/sandbox.zig").SandboxBackend; // ← Tools depends on Security
```

This is **not** a violation — these are **infrastructure dependencies**, not domain coupling. Tools need to know about memory backends and security sandboxes because they are the execution surface. The dependency direction is still correct: tools depend on contracts (Memory VTable, SandboxBackend enum), not on internals.

---

## 8. Full VTable Inventory (15 interfaces, ~110+ implementations)

From exhaustive codebase mapping:

| # | VTable | Implementations | Factory Pattern | DDD Role |
|---|--------|----------------|-----------------|----------|
| 1 | `Provider` | 11 types (50+ services via compatible table) | Tagged union (`ProviderHolder`) | Strategy for AI Model Provider BC |
| 2 | `Channel` | 19+ types (Telegram, Discord, Signal, Slack, etc.) | Registry (`ChannelRegistry`) | Strategy for Messaging Platform BC |
| 3 | `Tool` | 38 types (shell, file_*, git, http, browser, etc.) | Heap-alloc + `allTools()` | Strategy for Tool Execution BC |
| 4 | `Memory` | 10 engines (SQLite, Markdown, Redis, LanceDB, etc.) | Registry (config-driven) | Strategy for Memory Storage BC |
| 5 | `SessionStore` | 1 (SQLite) | Co-located with Memory | Session persistence within Memory BC |
| 6 | `EmbeddingProvider` | 3 (Noop, OpenAI, CustomUrl) | Direct construction | Embedding strategy for Vector Search BC |
| 7 | `VectorStore` | 1 (SQLite shared) | Direct construction | Vector storage for Vector Search BC |
| 8 | `RetrievalSourceAdapter` | 2 (PrimaryAdapter, VectorAdapter) | Direct construction | Adapter for Hybrid Retrieval BC |
| 9 | `BootstrapProvider` | 3 (File, Null, Memory) | Direct construction | Bootstrap data source for Bootstrap BC |
| 10 | `Sandbox` | 5 (Noop, Landlock, Firejail, Bubblewrap, Docker) | Auto-detect factory | Security sandbox for Security BC |
| 11 | `RuntimeAdapter` | 3 (Native, Wasm, Cloudflare) | Direct construction | Execution environment for Runtime BC |
| 12 | `Observer` | 6 (Noop, Log, Verbose, File, Otel, Runtime) | Direct construction | Observability for Observability BC |
| 13 | `TunnelAdapter` | 5 (None, Cloudflare, Ngrok, Tailscale, Custom) | Direct construction | Network tunnel for Infrastructure BC |
| 14 | `Peripheral` | 4 (Serial, Arduino, RPi GPIO, NucleoFlash) | Direct construction | Hardware I/O for Hardware BC |
| 15 | `Transcriber` | 1 (Whisper via Groq/OpenAI/Telnyx) | Direct construction | Voice transcription for Voice BC |

---

## 9. Dependency Map (Verified from Import Analysis)

### Init Order (from `src/root.zig`)
```
Phase 1 (Core)      → bus, config, util, platform, version, state, json_util, http_util
Phase 2 (Agent)     → agent, session, providers, memory, bootstrap
Phase 3 (Network)   → gateway, channels, a2a
Phase 4 (Extensions)→ security, cron, health, tools, identity, cost, observability, heartbeat,
                      runtime, mcp, subagent, auth, multimodal, agent_routing
Phase 5 (Hardware)  → hardware, peripherals, rag, skillforge, tunnel, voice
```

### Dependency Graph
```
                    ┌─────────────────────────────────────────────────┐
                    │              agent/root.zig                     │
                    │  (Application BC — orchestrates ALL subsystems) │
                    └──────┬──────┬──────┬──────┬──────┬──────┬──────┘
                           │      │      │      │      │      │
              ┌────────────┘      │      │      │      │      └────────────┐
              ▼                   ▼      ▼      ▼      ▼                   ▼
        ┌──────────┐      ┌──────────┐ │  ┌────────┐ │  ┌──────────┐ ┌──────────┐
        │ Provider │      │ Channel  │ │  │  Tool  │ │  │  Memory  │ │ Observer │
        └──────────┘      └──────────┘ │  └───┬────┘ │  └──────────┘ └──────────┘
                                       │      │      │
                                       │      ▼      │
                                       │  ┌────────┐ │
                                       └─►│Sandbox │◄┘
                                          └────────┘
```

### Cross-Subsystem Coupling (Only 3 minor, all acceptable)
| Coupling | From → To | Reason | DDD Assessment |
|----------|-----------|--------|----------------|
| `delegate.zig:11` | Tool → Provider | Sub-agent delegation needs to create providers | Acceptable — delegation IS about crossing BCs |
| `cron.zig:10-11` | Cron → Telegram/Signal | Cron-triggered notifications | Acceptable — cron is application-layer scheduling |
| `agent/root.zig:12-28` | Agent → Everything | Orchestrator | Expected — agent IS the application layer |

**Zero violations**: No provider→channel, channel→tool, tool→provider, or memory→provider imports. Architecture is clean with inward-pointing dependencies toward contracts.

### DDD Layer Classification
| Layer | Modules |
|-------|---------|
| **Shared Kernel** | `config_types.zig`, `platform.zig`, `http_util.zig`, `json_util.zig`, `bus.zig` |
| **Application** | `agent/`, `gateway.zig`, `daemon.zig`, `session.zig`, `subagent.zig` |
| **Domain** | `providers/`, `channels/`, `tools/`, `memory/`, `security/` |
| **Infrastructure** | `runtime.zig`, `tunnel.zig`, `peripherals.zig`, `voice.zig`, `observability.zig` |

---

## 10. Mental Model Summary

```
DDD Strategic Design          Zig VTable Pattern
─────────────────────────     ─────────────────────
Bounded Context         →     Subsystem (providers/, channels/, tools/)
Ubiquitous Language     →     Types in root.zig (ChatRequest, ToolResult)
Anti-Corruption Layer   →     VTable struct (the interface definition)
Strategy Implementation →     Concrete struct + vtable wiring
Factory                 →     Registration function (creates + wires)
Open Host Service       →     Optional vtable methods (?*const fn)
Context Map             →     Dependency direction between subsystems
Aggregate Root          →     Caller owns the implementing struct
Domain Event            →     Return types that cross boundaries (ChatResponse)
Published Language      →     ToolSpec (JSON schema for LLM function calling)
Shared Kernel           →     config.zig, util modules
Infrastructure          →     http_util, json_util, security/
```

**The single most important insight:**

> **A VTable is a DDD Bounded Context boundary made explicit in code.**
> 
> Everything inside the VTable definition is the Ubiquitous Language of that context.
> Everything outside (the concrete implementation) is infrastructure.
> The caller interacts with the language, never with the infrastructure.
> 
> Adding a new Provider/Channel/Tool = implementing a Strategy within a Bounded Context.
> The VTable is the contract. The factory wires it up. The caller uses it polymorphically.
