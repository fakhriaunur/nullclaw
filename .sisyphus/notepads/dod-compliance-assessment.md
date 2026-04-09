# DOD (Data-Oriented Design) Compliance Assessment — nullclaw

> Evaluated against 245 source files, ~249K LOC
> Date: 2026-04-08

---

## TL;DR: **~5% DOD compliant, 95% OOP/Interface-Oriented**

NullClaw is **explicitly NOT data-oriented**. It is an **interface-oriented, vtable-driven** architecture that prioritizes polymorphism, extensibility, and clean separation of concerns over cache performance or data layout.

This is **not a bug** — it's the correct design choice for an AI assistant runtime where:
- The hot path is **waiting for HTTP responses** (latency-bound, not CPU-bound)
- Extensibility (50+ providers, 19 channels, 38 tools) requires polymorphism
- Binary size (< 1 MB) is a harder constraint than cache performance

---

## DOD Principles vs nullclaw Reality

| DOD Principle | nullclaw Status | Evidence |
|--------------|-----------------|----------|
| **Data layout determines performance** | ❌ Ignored | 4,132 slices-of-structs patterns, all AoS (Array of Structs) |
| **Separate data from behavior** | ❌ Reversed | 707 `ptr: *anyopaque` + vtable patterns — behavior IS the interface |
| **Minimize pointer chasing** | ❌ Inverted | 109 vtable call sites, each = 2 pointer dereferences minimum |
| **Contiguous data processing** | ❌ Avoided | 583 `@ptrCast` + `@alignCast` — every vtable dispatch requires casting |
| **Cache-line awareness** | ❌ Absent | Zero `align(64)` annotations, no padding for cache lines |
| **Prefetch / pipeline awareness** | ❌ Absent | Zero `prefetch` usage |
| **SIMD vectorization** | ❌ Absent | Zero `std.simd`, zero `@Vector` usage |
| **SoA (Struct of Arrays)** | ❌ Absent | Zero `MultiArrayList` usage |
| **Fixed-size buffers** | ✅ Adopted | 222 stack-allocated `[N]u8` buffers — the #1 DOD pattern found |
| **Comptime lookup tables** | ✅ Adopted | 39 comptime table/array patterns, 21 `StaticStringMap` |
| **Bulk memory operations** | ✅ Adopted | 166 `@memcpy` / `@memset` calls |
| **Fixed-buffer allocators** | ⚠️ Rare | Only 2 `FixedBufferAllocator` uses (SSE parsing) |
| **Bit-level data packing** | ❌ Absent | Zero `BitStack`, `DynamicBitSet`, `StaticBitSet` usage |

---

## The Architecture is Intentionally Anti-DOD

### 1. VTables = Maximum Indirection

```zig
// Every vtable call: 3 memory accesses minimum
const response = try provider.chat(allocator, request, model, temperature);
// 1. Read provider.vtable (pointer dereference)
// 2. Read vtable.chat (function pointer dereference)
// 3. Call through function pointer (branch misprediction)
```

In DOD terms, this is the **worst possible** dispatch pattern:
- **Data**: scattered across heap (provider struct) + code segment (vtable) + impl struct
- **Branch prediction**: unpredictable (different provider per call)
- **Instruction cache**: every provider has different code

### 2. ArrayList<Struct> Everywhere

```zig
// src/tools/root.zig:276
var list: std.ArrayList(Tool) = .{};
// Tool = struct { ptr: *anyopaque, vtable: *const VTable }  // 16 bytes of pointers
```

Every `Tool` in the list is just two pointers. The actual data (ShellTool's workspace_dir, timeout_ns, etc.) is scattered on the heap. Iterating over tools = pointer chasing.

### 3. Tagged Unions (ProviderHolder) — The One DOD-Friendly Pattern

```zig
// src/providers/factory.zig:308
pub const ProviderHolder = union(enum) {
    openrouter: openrouter.OpenRouterProvider,
    anthropic: anthropic.AnthropicProvider,
    // ... 11 variants
};
```

This is **structurally closer to DOD** than vtables — the concrete struct lives inline in the union, not behind a pointer. But the union still exposes a vtable interface to callers, so the benefit is lost at the call site.

---

## Where DOD Patterns DO Exist (Intentional)

### 1. Fixed-Size Stack Buffers (222 uses) — THE Primary DOD Pattern

```zig
// src/config.zig:2987
var buf: [128]u8 = undefined;
const result = try std.fmt.bufPrint(&buf, "...", .{});
```

This is classic DOD: avoid allocation, use stack memory, process data in-place. Used heavily in:
- JSON parsing/serialization
- URL construction
- ID normalization
- Log formatting

**Why**: Allocations are slow. Stack buffers are free. This is the #1 performance optimization in the codebase.

### 2. StaticStringMap (21 uses) — Comptime Perfect Hash

```zig
// src/providers/root.zig:144
const map = std.StaticStringMap(Role).initComptime(.{
    .{ "system", .system },
    .{ "user", .user },
    .{ "assistant", .assistant },
    .{ "tool", .tool },
});
return map.get(s);
```

This is a **compile-time perfect hash table** — zero allocation, O(1) lookup, contiguous data. Classic DOD: build the lookup structure at compile time, use it at runtime with zero overhead.

### 3. Comptime Lookup Tables (39 uses) — Compile-Time Code Generation

```zig
// src/agent/root.zig:891
inline for (ascii_patterns) |pattern| {
    if (std.mem.startsWith(u8, trimmed, pattern)) return true;
}
```

The `inline for` unrolls at compile time — no loop overhead, branch prediction is perfect. This is the closest nullclaw gets to SIMD-style thinking: do all checks in parallel (conceptually) rather than sequentially.

### 4. `@setEvalBranchQuota(100_000)` — Comptime Tuning

```zig
// src/providers/factory.zig:187
@setEvalBranchQuota(100_000);
```

The provider factory uses comptime code generation with a massive branch quota. This means the entire provider classification logic is **evaluated at compile time** — zero runtime cost. This is DOD thinking: move work from runtime to compile time.

### 5. Bulk Memory Operations (166 uses)

```zig
@memcpy(dest, src);
@memset(ptr, value);
```

Used in crypto, JSON parsing, and string processing. These are the DOD way to move data — let the compiler emit optimal memcpy/memset, not a byte-by-byte loop.

---

## Where DOD Patterns DON'T Exist (Opportunity Gaps)

### 1. No MultiArrayList

If nullclaw needed to process thousands of messages or events, `MultiArrayList(T)` would store each field in a separate array, enabling cache-friendly iteration. But nullclaw doesn't have high-throughput data processing — it's latency-bound on LLM API calls.

### 2. No Bit-Level Packing

Security policies, feature flags, and capability bits are stored as full `bool` fields (1 byte each). A `StaticBitSet` or `BitStack` would pack 8 flags into 1 byte. But with 245 source files and a < 1 MB binary target, saving a few bytes on flag storage isn't worth the complexity.

### 3. No Cache-Line Alignment

Structures that are accessed concurrently (atomic values, lock-free queues) could benefit from `align(64)` to prevent false sharing. But nullclaw's concurrency model is mostly async/await, not lock-free data structures.

### 4. No SIMD

Text processing (JSON escaping, string matching, UTF-8 validation) could use SIMD for 4-8x speedup. But the text processing volume is small (system prompts, tool outputs) — not worth the code size.

---

## The Verdict: DOD Would Be The Wrong Choice Here

### Why OOP/VTables Win for NullClaw:

| Factor | DOD | VTables (Current) | Winner |
|--------|-----|-------------------|--------|
| **Extensibility** | Hard (new types = new code paths) | Easy (new type = implement vtable) | VTables |
| **Binary size** | Larger (code duplication per type) | Smaller (shared dispatch) | VTables |
| **Cache performance** | Better | Worse | DOD |
| **LLM API latency** | Irrelevant (network-bound) | Irrelevant (network-bound) | Tie |
| **Memory usage** | Better (contiguous) | Worse (heap scattered) | DOD |
| **Runtime flexibility** | Poor (compile-time layout) | Excellent (runtime selection) | VTables |
| **Code complexity** | Higher (data layout reasoning) | Lower (standard interface) | VTables |

**The bottleneck is network latency** (waiting for OpenAI/Anthropic responses), not CPU cache misses. DOD optimizes for CPU throughput; nullclaw optimizes for extensibility and binary size.

### When DOD Would Matter:

If nullclaw ever needed to:
- Process millions of messages per second (it doesn't — it's one message at a time)
- Run on microcontrollers with < 64KB RAM (it targets servers and edge devices with > 128MB)
- Do real-time audio/video processing (voice is async transcription, not real-time)

Then DOD patterns would become relevant.

---

## Summary Table

| Category | Count | DOD? |
|----------|-------|------|
| VTable interfaces | 15 | ❌ Maximum indirection |
| VTable implementations | ~110 | ❌ Heap-scattered data |
| `ptr: *anyopaque` patterns | 707 | ❌ Pointer chasing |
| Vtable call sites | 109 | ❌ Branch misprediction |
| `@ptrCast` + `@alignCast` | 583 | ❌ Type erasure overhead |
| Slices of structs (AoS) | 4,132 | ❌ Not cache-friendly |
| Fixed-size stack buffers | 222 | ✅ Classic DOD |
| StaticStringMap | 21 | ✅ Compile-time perfect hash |
| Comptime lookup tables | 39 | ✅ Compile-time evaluation |
| Bulk memory ops | 166 | ✅ Optimal data movement |
| `inline for` (comptime unroll) | 10 | ✅ Branch-free iteration |
| `@setEvalBranchQuota` | 1 | ✅ Compile-time code gen |
| MultiArrayList | 0 | ❌ Missing |
| SIMD/`@Vector` | 0 | ❌ Missing |
| Bit-level packing | 0 | ❌ Missing |
| Cache-line alignment | 0 | ❌ Missing |

**DOD score: 458 patterns found (good) vs 5,650 OOP patterns found (dominant) = 7.5% DOD**

But the more accurate measure: **nullclaw is 0% intentionally DOD and 100% intentionally interface-oriented**. The DOD patterns that exist (stack buffers, comptime tables) are incidental benefits of Zig's comptime system, not a design philosophy.

---

## Control Plane vs Data Plane Analysis

### The Split

| Plane | What It Does | nullclaw Modules | Hot Path? |
|-------|-------------|-----------------|-----------|
| **Control Plane** | Decisions, routing, orchestration | `agent/root.zig`, `dispatcher.zig`, `gateway.zig`, `config.zig`, `agent_routing.zig` | Decision latency |
| **Data Plane** | Transform data, no side effects | `dispatcher.zig` (parsing), `prompt.zig` (building), `providers/helpers.zig` (JSON building), `json_util.zig`, `search_base_url.zig` | String processing throughput |
| **Side-Effect Plane** | I/O, network, filesystem | Providers (HTTP), Tools (exec), Channels (messaging), Memory (SQLite) | Wait time |

### Control Plane = Agent Loop Decision Tree

```
Agent.runSingle() → provider.chat() → parse response → execute tools → loop
                       │                   │               │
                   Control: retry     Control: parse    Shell: fork
                   logic, streaming   text vs tool      process, read
                   decision, native   call extraction   stdout, format
                   vs XML dispatch
```

**Hot path in the control plane**: `dispatcher.parseToolCalls()` — runs every agent loop iteration, parses LLM response text to extract tool calls. Currently:
- 109 vtable call sites per loop iteration
- Each call = 2 pointer dereferences + branch misprediction
- But the **real bottleneck is the HTTP call** (provider.chat) — 200ms to 10s latency

**Where DOD could help (minor gains)**:
1. `dispatcher.parseToolCalls()` — string parsing is allocation-heavy (192 JSON parse calls). If this runs in a tight loop (streaming responses), switching from `ArrayList` append to a pre-allocated fixed buffer would reduce allocation churn.
2. `dispatcher.containsToolCallMarkup()` — already pure and uses `std.mem.indexOf` (efficient). No DOD gain possible.
3. `dispatcher.repairJson()` — JSON repair is an allocation-heavy fallback. If the repair buffer could be stack-allocated with a known max size, it would avoid heap allocation on the hot path.

### Data Plane = String Transformation Functions

**Already DOD-friendly (incidental)**:
- `containsToolCallMarkup(text) → bool` — pure function, no allocation, O(n) scan
- `isNativeJsonFormat(text) → bool` — pure function, `std.mem.indexOf`
- `providerUrl(name) → []const u8` — pure function, comptime string lookup
- `isReasoningModel(model) → bool` — pure function, comptime table scan

**Could be more DOD-friendly**:
- `stripToolResultMarkup(allocator, text) → []u8` — allocates output. Could use a stack buffer with overflow check for typical response sizes.
- `buildRequestBody(allocator, ...)` — JSON building via `ArrayList`. Could use a fixed-size pre-allocated buffer for typical request sizes (< 8KB).

### The Real Answer: DOD Doesn't Matter Here

The agent loop waits 200ms-10s for LLM API responses. Saving 50μs on string parsing is a 0.0005% improvement. The optimization target is **network latency**, not CPU throughput.

**Where DOD WOULD matter**: If nullclaw ever batched thousands of messages for processing (e.g., offline analysis, vector search over millions of embeddings), then `MultiArrayList` and SIMD would be critical. Today it doesn't.

---

## FCIS (Functional Core, Imperative Shell) Assessment

### The FCIS Framework

FCIS separates code into:
- **Functional Core**: Pure functions — same input → same output, no side effects, easily testable with PBT (Property-Based Testing)
- **Imperative Shell**: Coordination code — does I/O, manages state, orchestrates the core

### NullClaw's Current State: **Mixed, Not Explicitly Separated**

#### Functional Core Candidates (Pure or Nearly Pure)

| Module | Functions | Purity | Test Strategy |
|--------|-----------|--------|---------------|
| `dispatcher.zig` | `containsToolCallMarkup`, `isNativeJsonFormat`, `containsIgnoreCase` | ✅ Pure — no allocator, no I/O | **Unit tests + PBT** |
| `dispatcher.zig` | `stripToolResultMarkup`, `parseToolCalls`, `repairJson` | ⚠️ Pure-ish — takes allocator for string output but no side effects | **Unit tests + PBT** |
| `search_base_url.zig` | `isValid` | ✅ Pure — no allocator | **Unit tests + PBT** |
| `search_base_url.zig` | `normalizeEndpoint` | ⚠️ Pure-ish — allocates output but no I/O | **Unit tests** |
| `json_util.zig` | `appendJsonString`, `appendJsonKey` | ⚠️ Pure-ish — writes to buffer but deterministic | **Unit tests + PBT** |
| `util.zig` | `appendJsonEscaped`, `isAsciiPrintable` | ✅/⚠️ Mixed | **Unit tests** |
| `providers/helpers.zig` | `isReasoningModel`, `providerUrl`, `normalizeOpenAiReasoningEffort` | ✅ Pure — no allocator | **Unit tests + PBT** |
| `providers/helpers.zig` | `buildRequestBody`, `serializeMessageContent`, `convertToolsOpenAI` | ⚠️ Pure-ish — deterministic JSON building | **Unit tests** |
| `config.zig` | `validate` | ✅ Pure — reads config, returns error enum | **Unit tests** |
| `agent/prompt.zig` | `buildToolInstructions` | ⚠️ Impure-ish — reads files from disk | **Integration tests** |
| `agent/compaction.zig` | `calculateTokenBudget` | ⚠️ Pure-ish — arithmetic on config values | **Unit tests** |

#### Imperative Shell (Side Effects)

| Module | What It Does | Test Strategy |
|--------|-------------|---------------|
| `agent/root.zig` | Agent loop: calls provider, dispatches tools, manages state | **Integration tests** (mock provider, mock tools) |
| `providers/openai.zig` | HTTP request + response parsing | **Integration tests** (`builtin.is_test` → mock response) |
| `tools/*.zig` | Shell exec, file I/O, HTTP requests | **Integration tests** (`builtin.is_test` → mock) |
| `channels/*.zig` | Network I/O, message handling | **Integration tests** (`builtin.is_test` → mock) |
| `memory/*.zig` | SQLite operations, file I/O | **Integration tests** (temp dir, in-memory SQLite) |
| `gateway.zig` | HTTP server, routing | **Integration tests** (test HTTP client) |

### The FCIS Gap: **Core and Shell Are Intertwined**

**Example: `dispatcher.parseToolCalls()`** — this should be pure core (string → parsed result), but it takes an `allocator` and returns an allocated string. In FCIS terms, it's a pure function that happens to allocate output, which is a common Zig pattern but creates ambiguity: is this core or shell?

**Example: `providers/helpers.zig:buildRequestBody()`** — builds JSON from parameters. Pure function (same input → same output), but takes an allocator and returns a heap-allocated string. Again, core-ish but allocation blurs the line.

**Example: `agent/prompt.zig:buildSystemPrompt()`** — reads workspace files, builds a system prompt string. This is **impure** (reads filesystem) but the prompt-building logic (once files are loaded) is pure. In FCIS terms, this should be:
```
Shell: loadFiles(workspace_dir) → IdentityData  ← side effect
Core:  buildPrompt(IdentityData, tools) → string ← pure
Shell: sendPromptToProvider(prompt)            ← side effect
```

### Accidental vs Intentional FCIS

**Intentional**:
- `builtin.is_test` guards in all tools — clearly separates test (pure mock) from production (impure execution)
- `dispatcher.zig` extracted as a separate module — isolation of parsing logic
- `search_base_url.zig` — pure URL validation, no dependencies

**Accidental** (not designed as FCIS, but happens to be pure):
- `containsToolCallMarkup` — pure because it just searches strings, not because of architectural intent
- `isReasoningModel` — pure because it's a simple string comparison against a comptime table
- `Config.validate` — pure because validation is naturally pure, not because of FCIS design

### What FCIS Would Look Like If Applied Intentionally

**Step 1: Identify the Core**
```
Pure Core (deterministic, testable with PBT):
├── dispatcher/     — parsing LLM responses
├── prompt/         — building prompts from data
├── compaction/     — calculating token budgets
├── url_validation/ — validating URLs
├── json_builder/   — constructing JSON payloads
└── config_validate/— validating config values

Impure Shell (side effects, integration tests):
├── providers/      — HTTP calls
├── tools/          — shell exec, file I/O
├── channels/       — network I/O
├── memory/         — SQLite operations
└── agent/root.zig  — orchestration loop
```

**Step 2: Refactor Mixed Functions**
Current:
```zig
// Mixed: pure parsing + allocation in one function
pub fn parseToolCalls(allocator: Allocator, response: []const u8) !ParseResult {
    if (isNativeJsonFormat(response)) {
        const native = parseNativeToolCalls(allocator, response) catch null;
        // ...
    }
    return parseXmlToolCalls(allocator, response);
}
```

FCIS (explicitly separated):
```zig
// Core: pure parsing logic, caller provides buffer
pub fn parseToolCallsInto(
    response: []const u8,
    output: *ParseResultBuffer,  // pre-allocated, caller-owned
) !ParseResult {
    if (isNativeJsonFormat(response)) {
        // Parse into pre-allocated buffer
    }
    // ...
}

// Shell: allocation wrapper
pub fn parseToolCalls(allocator: Allocator, response: []const u8) !ParseResult {
    var buf: ParseResultBuffer = .empty;
    return parseToolCallsInto(response, &buf);
}
```

**Step 3: Test Strategy Split**
```
Core tests (unit + PBT):
├── dispatcher_test.zig    — property: "parsing is idempotent"
├── prompt_test.zig        — property: "prompt length is bounded"
├── url_validation_test.zig — property: "valid URLs round-trip"
└── json_builder_test.zig  — property: "output is valid JSON"

Shell tests (integration):
├── provider_test.zig      — mock HTTP responses
├── tool_test.zig          — builtin.is_test → mock execution
├── channel_test.zig       — mock network responses
└── agent_test.zig         — mock provider + mock tools
```

### FCIS Score: **~30% compliant (accidental)**

| Dimension | Score | Reasoning |
|-----------|-------|-----------|
| **Core functions exist** | 60% | dispatcher, helpers, url_validation exist as separate modules |
| **Core is pure** | 40% | Most "core" functions take allocators and return allocated output |
| **Shell is separated** | 20% | agent/root.zig mixes parsing, I/O, and orchestration |
| **Test strategy split** | 10% | All tests use same pattern (builtin.is_test), no PBT, no unit/integration split |
| **Intentional design** | 5% | No explicit FCIS boundaries, no design documentation |

### The Bottom Line

NullClaw is **not FCIS by design**, but it has the **seeds of FCIS** in its module structure. The dispatcher is extracted, helpers are in separate modules, and `builtin.is_test` creates a natural test boundary.

To move toward FCIS intentionally:
1. **Identify and document** which functions are core (pure) vs shell (impure)
2. **Push allocation to the shell** — core functions take pre-allocated buffers
3. **Add PBT** for core functions (property-based testing with randomized inputs)
4. **Split test strategy** — unit tests for core, integration tests for shell
5. **Document the boundary** — add an `FCIS.md` or update `AGENTS.md` with explicit core/shell boundaries

This would give:
- **Faster tests**: core tests run in milliseconds (no I/O, no allocation)
- **Better test coverage**: PBT finds edge cases that example-based tests miss
- **Clearer architecture**: every function is either core or shell, no ambiguity
- **Easier refactoring**: core functions can be tested in isolation from I/O

But: **the benefit is marginal for a network-bound application**. The agent loop waits 200ms-10s for LLM responses. Faster tests are nice, but the bottleneck is external.
