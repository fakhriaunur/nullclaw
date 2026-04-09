# Bug Fix Patterns

## Config Wiring Fixes (cfb6291, 38ee80f)

### Fix 1: Reserve `main` as Root Agent ID (38ee80f)

**Commit:** `38ee80ffd2b3f320078c9cb00fb83c35a1281581`
**Title:** `fix(config): reserve main as root agent id`
**Files changed:** `src/config.zig` (33 lines added)

#### Root Cause
Named agents configured in `agents.list` could be given a name like `"Main"` or `"MAIN"` that, after normalization via `agent_routing.normalizeId()`, would resolve to `"main"` — the reserved ID for the root agent. This created a routing collision: sessions targeting `agent:main:*` could resolve to a named agent instead of the root configuration, causing unpredictable behavior or silent misrouting.

There was no validation at config-load time to prevent this collision. The config schema accepted any string as a named agent name without checking for reserved identifiers.

#### Fix Approach
1. Added `namedAgentUsesReservedRootId(agent_name: []const u8) bool` helper that normalizes the agent name into a 64-byte stack buffer and checks for equality with `"main"`.
2. Added `ValidationError.ReservedMainAgentName` to the `Config.ValidationError` enum.
3. Extended `Config.validate()` to iterate `self.agents`, calling the helper for each entry and returning the new error variant on match.
4. Added a regression test with a named agent `name = "Main"` that verifies `ValidationError.ReservedMainAgentName` is returned.
5. Added user-facing error message: `"Config error: agents.list names must not normalize to 'main' because that id is reserved for the root agent."`

The fix uses `agent_routing.normalizeId` directly — the same normalization function used at routing time — ensuring the validation check matches the runtime behavior exactly.

#### Diff Key Excerpts
```zig
// New helper function
fn namedAgentUsesReservedRootId(agent_name: []const u8) bool {
    var agent_buf: [64]u8 = undefined;
    return std.mem.eql(u8, agent_routing.normalizeId(&agent_buf, agent_name), "main");
}

// New validation error variant
pub const Config = struct {
    pub const ValidationError = enum {
        // ... existing variants ...
        ReservedMainAgentName,
        // ...
    };

    pub fn validate(self: *const Config) ValidationError!void {
        // ... existing validations ...
        for (self.agents) |agent_cfg| {
            if (namedAgentUsesReservedRootId(agent_cfg.name)) {
                return ValidationError.ReservedMainAgentName;
            }
        }
        // ...
    }
};
```

#### Similar-Risk Assessment
**Other reserved identifiers that could have similar gaps:**
- The root agent ID `"main"` is the only explicitly reserved name at the config validation layer.
- Other hardcoded IDs in routing (`"agent:"` prefix pattern, `"global"` session keys) are structural and not user-configurable, so they don't have the same collision surface.
- However, if future features introduce additional reserved names (e.g., `"system"`, `"global"`, `"root"`), the same pattern should be applied: add them to the validation loop with a clear error variant.
- **Actionable check:** Audit `src/agent_routing.zig` for any other string literals that serve as reserved identifiers and verify they have corresponding config validation.

---

### Fix 2: Clarify Config Literal Values + Routing Revert (cfb6291)

**Commit:** `cfb62910fe151e88e2b0f1784b617475bf05488a` (merge PR #706)
**Branch:** `fix-697` — contained 4 commits, with the final state being:
- `c37abb1` — docs: clarify literal config values in README
- `1281837` — revert: restore named-agent default routing
- `0f2d850` — docs: clarify no env var interpolation (bilingual)
- `1410a8b` — fix(routing): always use "main" as default (later reverted)

**Files changed:** `README.md` (6 lines), `src/agent_routing.zig` (14 lines net)

#### Root Cause
This merge captures a two-part story:

**Part A — Documentation gap (issue #697):** Users assumed NullClaw's `config.json` supports environment variable interpolation (e.g., `"${MY_TOKEN}"`). It does not — all config values are literal strings. This led to misconfigured headers, secrets being stored as literal `${VAR}` text, and runtime failures that were hard to diagnose.

**Part B — Routing regression and revert:** An earlier commit (`1410a8b`) attempted to fix default agent routing by making `findDefaultAgent()` always return `"main"` regardless of whether named agents exist. This was then reverted (`1281837`) because it broke the intended behavior: when named agents are configured, the first named agent should be the default, not the root agent.

The original broken behavior was:
```zig
// Before fix, then reverted — this was the CORRECT behavior
pub fn findDefaultAgent(agents: []const NamedAgentConfig) []const u8 {
    if (agents.len > 0) return agents[0].name;
    return "main";
}
```

The incorrect fix (`1410a8b`) changed it to:
```zig
// WRONG — always returns "main", ignoring named agents
pub fn findDefaultAgent(agents: []const NamedAgentConfig) []const u8 {
    _ = agents;
    return "main";
}
```

The revert (`1281837`) restored the original correct behavior.

#### Fix Approach
1. **Documentation fix:** Added explicit clarification to `README.md` under the config example section:
   ```
   Config values are literal. NullClaw does not expand `${VAR}` inside config.json
   strings, including custom header values. If you need environment-based secrets,
   render config.json ahead of time with your own deployment tooling.
   ```
   Also replaced misleading placeholder `<YOUR_MCP_TOKEN>` with `example-token` to avoid suggesting template syntax.

2. **Routing revert:** Restored `findDefaultAgent()` to return `agents[0].name` when agents exist, `"main"` otherwise. Updated tests to match the restored behavior.

#### Diff Key Excerpts
```markdown
# README.md addition (c37abb1)
+Config values are literal. NullClaw does not expand `${VAR}` inside `config.json`
+strings, including custom header values. If you need environment-based secrets,
+render `config.json` ahead of time with your own deployment tooling.
```

```zig
// agent_routing.zig — final state after revert (1281837)
/// Find the default agent from a named agents list.
/// Returns the first agent's name, or "main" if the list is empty.
pub fn findDefaultAgent(agents: []const NamedAgentConfig) []const u8 {
    if (agents.len > 0) return agents[0].name;
    return "main";
}
```

#### Similar-Risk Assessment
- **Env var interpolation:** No other config fields are at risk because the parser treats all JSON strings as literals — there's no interpolation engine to fix. The risk is purely in user expectations, which documentation now addresses.
- **Default agent routing:** The `findDefaultAgent()` function is the single source of truth for default resolution. The revert fixed the immediate regression, but the broader risk is that `findDefaultAgent` can return a named agent name that doesn't exist in the provider registry. This should be validated at config load time — if a named agent references an unknown provider, the config should reject it early rather than failing at routing time.
- **Actionable check:** Verify that `Config.validate()` checks whether each named agent's `.provider` field maps to a registered provider factory key. If not, this is a similar wiring gap.

---

### Cross-Cutting Patterns Observed

1. **Validation-at-load > fail-at-runtime:** Both fixes point to a pattern where config validation should catch problems early (reserved names, provider existence) rather than letting them surface as routing errors at runtime.
2. **Reserved identifiers need validation:** Any hardcoded identifier used in routing/lookup paths should have a corresponding config validation check to prevent user config from colliding with internal names.
3. **Documentation as a config-layer fix:** When the parser behavior is intentional (no env var expansion), clear documentation is the correct fix — not adding new parser features.
4. **Revert discipline:** The revert in cfb6291 demonstrates correct practice — when a fix introduces a regression, revert fully (including tests) rather than patching the patch.

---

## Provider Handling Fixes (be0b18f, 03aa8bb)

### Fix 1: Versionless Custom Provider URL Parsing (be0b18f)

**Commit:** `be0b18fc57a8906ee232c367d16af3874f97bef9`
**Title:** `Merge origin/main and fix versionless custom provider handling`
**Core files changed:** `src/model_refs.zig` (new, 243 lines), `src/config.zig`, `src/config_parse.zig`, `src/config_types.zig`, `src/providers/compatible.zig`, `src/providers/factory.zig`

#### Root Cause

The config parser used a fragile, hard-coded heuristic inside `splitPrimaryModelRef()` (in `config.zig`) to parse `custom:<url>/<model>` references. The old algorithm scanned for versioned API segments like `/v1/`, `/v2/` to determine where the URL ends and the model name begins. When a custom provider URL had **no version segment** (e.g., `custom:https://gateway.example.com/qianfan/custom-model`), the parser fell back to splitting at the **first `/`** after `custom:`. This meant refs like `custom:https://gateway.example.com/minimaxai/minimax-m2.1` were catastrophically misparsed as provider=`custom:https:` and model=`gateway.example.com/minimaxai/minimax-m2.1`, breaking restart persistence for any versionless custom URL provider whose model path contained a known provider namespace segment.

#### Fix Approach

1. **Extracted `model_refs.zig`** — a new dedicated module with a multi-strategy splitting pipeline:
   - `splitKnownEndpointUrlProviderModel` — preserves `/chat/completions/` and `/responses/` endpoint suffixes
   - `splitVersionedUrlProviderModel` — legacy `/v1/`, `/v2/` detection (backward compat)
   - `splitKnownProviderNamespaceUrlModel` — scans for known provider namespace segments (`qianfan`, `minimaxai`, `openai`, etc.) from a 39-entry `StaticStringMap`
   - `splitLastUrlPathSegment` — fallback: split at last `/` in URL path
   - Strategies tried in order; first match wins

2. **Two-phase parsing in `config_parse.zig`** — `collectExplicitProviderNames()` first gathers all configured provider names from `models.providers`, `model_routes`, and `reliability.fallback_providers`. Then `splitProviderModelWithKnownProviders()` matches the model ref against these explicit names using longest-prefix-match before falling back to the heuristic pipeline.

3. **Replaced inline logic** — `splitPrimaryModelRef()` now delegates to `model_refs.splitProviderModel()`, reducing ~50 lines of nested inline parser to a 4-line delegation.

#### Diff Key Excerpts

```zig
// NEW: src/model_refs.zig — multi-strategy splitting
const known_url_model_provider_namespaces = std.StaticStringMap(void).initComptime(.{
    .{ "openai", {} }, .{ "anthropic", {} }, .{ "qianfan", {} },
    .{ "minimaxai", {} }, .{ "minimax", {} }, .{ "glm", {} },
    // ... 39 known provider namespace entries total
});

pub fn splitProviderModel(model_ref: []const u8) ?ProviderModelRef {
    if (std.mem.indexOf(u8, model_ref, "://")) |proto_start| {
        const url_start = proto_start + 3;
        if (splitKnownEndpointUrlProviderModel(model_ref, url_start)) |split| return split;
        if (splitVersionedUrlProviderModel(model_ref, url_start)) |split| return split;
        if (splitKnownProviderNamespaceUrlModel(model_ref, url_start)) |split| return split;
        return splitLastUrlPathSegment(model_ref, url_start);
    }
    const slash = std.mem.indexOfScalar(u8, model_ref, '/') orelse return null;
    return splitAtSlash(model_ref, slash);
}
```

```zig
// config_parse.zig — two-phase: collect explicit providers first
fn collectExplicitProviderNames(allocator: std.mem.Allocator, root: std.json.ObjectMap) ![]const []const u8 {
    // Gather from models.providers, model_routes[].provider, reliability.fallback_providers[]
    // Then splitPrimaryModelRefWithProviders uses these for longest-prefix-match
}
```

#### Similar-Risk Assessment

**HIGH RISK — Other providers likely affected:**
- Any custom provider using a **versionless URL** where the model path contains one of the 39 known provider namespace names (openai, anthropic, qwen, qianfan, minimaxai, glm, hunyuan, etc.) would have been misparsed before this fix.
- Custom providers whose model IDs contain `/` separators (e.g., `anthropic/claude-3-5-sonnet` as a model name under a custom gateway) were similarly at risk.
- The `known_url_model_provider_namespaces` map introduces a **maintenance burden**: every new provider brand must be added to benefit from namespace-aware splitting. Missing entries fall back to `splitLastUrlPathSegment`, which may still produce incorrect results for multi-segment model IDs.

**MITIGATION:** The two-phase approach (`splitProviderModelWithKnownProviders` using explicitly configured provider names) means users who define their provider in config get correct parsing regardless of whether the namespace is in the known list.

---

### Fix 2: Gemini CLI ACP Handshake Alignment (03aa8bb)

**Commit:** `03aa8bb51626ac3b258939e46f59a56c1ffebbb3`
**Title:** `fix(gemini-cli): align ACP handshake with Gemini CLI 0.34`
**Files changed:** `src/providers/gemini_cli.zig` (+348/-86 lines)

#### Root Cause

The Gemini CLI provider's ACP (Agent Communication Protocol) handshake was out of sync with Gemini CLI version 0.34. The old code sent only a `session/new` RPC as the initial handshake, but Gemini CLI 0.34 requires an **`initialize` RPC first** that includes `protocolVersion` in the params. Without this, the Gemini CLI would reject the connection or behave unpredictably.

Additionally, the old handshake logic bundled session initialization into a single monolithic `start()` method, making error handling fragile — if handshake failed partway through, the provider would be left with a dangling `child` pointer and stale state (`child_argv`, `session_id`, `read_buffer`), causing segfaults on subsequent operations.

#### Fix Approach

1. **Added `initialize` RPC handshake step** — `buildInitializeRequest()` sends `{"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}` before `session/new`. Protocol version is a constant `ACP_PROTOCOL_VERSION: u32 = 1` for easy future updates.

2. **Split handshake into discrete methods:**
   - `initializeSession()` — orchestrates the two-step handshake
   - `sendJsonRpcLine()` — extracted write-with-newline helper
   - `readInitializeResponse(id)` — validates initialize response, checks `protocolVersion` is numeric
   - `readSessionNewResponse(id)` — returns allocated `sessionId` string

3. **Improved ID matching** — `responseIdMatches()` handles integer, float, **and string** response IDs. `floatResponseIdMatches()` adds NaN/infinity/fractional guards.

4. **Robust cleanup on failure** — `cleanupStartupFailure()` handles partially-spawned children. `resetConnectionState()` zeroes `child_argv`, `session_id`, `read_buffer`, and `read_offset`.

5. **Error recording** — `recordJsonRpcError()` stores JSON-RPC error details via `root.setLastApiErrorDetail()` for user-visible diagnostics.

6. **Manual JSON building** — `buildInitializeRequest()` and `buildSessionNewRequest()` use `ArrayListUnmanaged` with `appendSlice` instead of `std.json.Stringify.valueAlloc`, avoiding heap allocations.

#### Diff Key Excerpts

```zig
// Before: monolithic start() with session/new only
// After: two-step handshake with proper cleanup

fn initializeSession(self: *GeminiCliProvider) !void {
    const init_id = self.next_id;
    self.next_id += 1;
    const init_req = try buildInitializeRequest(self.allocator, init_id);
    defer self.allocator.free(init_req);
    try self.sendJsonRpcLine(init_req);
    try self.readInitializeResponse(init_id);

    const session_id = self.next_id;
    self.next_id += 1;
    const session_req = try buildSessionNewRequest(self.allocator, session_id, cwd);
    defer self.allocator.free(session_req);
    try self.sendJsonRpcLine(session_req);
    self.session_id = try self.readSessionNewResponse(session_id);
}

fn cleanupStartupFailure(self: *GeminiCliProvider, child: ?*std.process.Child, child_spawned: bool) void {
    if (child) |c| {
        if (child_spawned) { self.child = c; self.stopInternal(); return; }
        self.allocator.destroy(c);
    }
    self.child = null;
    self.resetConnectionState();
}
```

#### Similar-Risk Assessment

**MEDIUM RISK — Other CLI-based providers may have similar issues:**
- `gemini_cli.zig` is the only provider using ACP handshake, but any future CLI-based provider that communicates via stdin/stdout JSON-RPC would benefit from the same patterns: discrete handshake steps, proper failure cleanup, and string-tolerant ID matching.
- The `cleanupStartupFailure`/`resetConnectionState` pattern should be a template for any provider that spawns child processes with multi-step initialization. Without it, partial handshake failures leave the provider in an inconsistent state.
- The `responseIdMatches` function accepting string IDs is a good general pattern for JSON-RPC providers, as some implementations may serialize numeric IDs as strings.

**LOWER RISK — The fix is well-contained:**
- Only affects `GeminiCliProvider` internals. No vtable interface changes or factory wiring modifications.
- Protocol version constant makes future Gemini CLI protocol changes easy to handle with a single constant bump.

