# Bug Fix Selection: Candidate Analysis

## Patterns Reviewed

From `.sisyphus/drafts/bug-fix-patterns.md`:

### Pattern 1: Calculator Precision (82240a8)
- **Not found** in sprint worktree codebase. No calculator/precision-related modules
  present in `src/`.

### Pattern 2: Config Wiring — Reserved Identifier Validation (38ee80f)
- Already fixed in both repos. `Config.validate()` checks `namedAgentUsesReservedRootId()`
  for named agents colliding with reserved root agent ID `"main"`.
- **Actionable gap noted in patterns doc:**
  > Verify that `Config.validate()` checks whether each named agent's `.provider`
  > field maps to a registered provider factory key. If not, this is a similar
  > wiring gap.

### Pattern 3: Config Wiring — Env Var Interpolation Docs (cfb6291)
- Documentation-only fix. Already applied (README clarifies config values are literal).

### Pattern 4: Provider Handling — Versionless Custom Provider URL Parsing (be0b18f)
- Already fixed. `model_refs.zig` extracted with multi-strategy splitting pipeline.

### Pattern 5: Provider Handling — Gemini CLI ACP Handshake (03aa8bb)
- Already fixed. `gemini_cli.zig` has two-step initialize + session/new handshake.

## Candidate Files Evaluated

### Candidate A: `src/config.zig` — Missing Provider Validation for Named Agents

**Pattern match:** Config Wiring (Pattern 2 — actionable gap)

**Evidence:**
- `Config.validate()` iterates `self.agents` (line 1346) but only checks
  `namedAgentUsesReservedRootId(agent_cfg.name)`.
- It does NOT validate that `agent_cfg.provider` maps to a known provider.
- `classifyProvider()` in `providers/factory.zig` returns `.unknown` for unrecognized
  provider names (line 276), making detection straightforward.
- `config.zig` does NOT currently import or call `classifyProvider`.
- Same gap confirmed in both main repo and sprint worktree (identical code at line 1346-1350).

**Runtime impact:** If a user configures a named agent with a typo in the provider name
(e.g., `"openrout"` instead of `"openrouter"`), config validation passes cleanly. The
error only surfaces at runtime when the agent loop tries to resolve the provider,
producing a confusing failure instead of a clear config error.

**Existing tests:** `config.zig` has extensive validation tests (lines 1700-5700+)
following the pattern: construct a `Config` with bad data, call `validate()`,
`expectError` the specific `ValidationError` variant.

**Estimated fix size:** ~15-20 lines
- Add `UnknownAgentProvider` to `ValidationError` enum (~1 line)
- Add helper `fn isKnownProvider(name: []const u8) bool` (~5 lines, delegates to
  `providers.classifyProvider`)
- Extend `validate()` loop to check `agent_cfg.provider` (~3 lines)
- Add `printValidationError` case (~1 line)
- Add regression test (~5 lines)

**Risk assessment:** LOW
- Not in HIGH-risk paths (`security/`, `gateway.zig`, `tools/`, `runtime.zig`)
- Additive validation only — no existing behavior changes
- Follows exact same pattern as the existing `ReservedMainAgentName` check
- Well-tested module with established test patterns

### Candidate B: `src/agent_bindings_config.zig` — Missing Provider Validation in Binding Updates

**Pattern match:** Config Wiring (same gap, different module)

**Evidence:**
- `applyBindingUpdate()` calls `findNamedAgent(cfg.agents, raw_agent)` but does NOT
  validate the found agent's `.provider` field.
- `persistBindingUpdate()` calls `cfg.validate()` but validation has the same gap.

**Estimated fix size:** Would require fix in `config.zig` first (the validation gap
is in `Config.validate()`). The bindings module depends on config validation.

**Risk assessment:** LOW, but secondary to Candidate A.

### Candidate C: `src/agent_routing.zig` — Reserved Identifier Audit

**Pattern match:** Config Wiring (Pattern 2 — "Other reserved identifiers")

**Evidence from patterns doc:**
> Audit `src/agent_routing.zig` for any other string literals that serve as reserved
> identifiers and verify they have corresponding config validation.

**Findings:**
- `agent_routing.zig` contains `"main"` as root agent ID (already validated).
- Other hardcoded identifiers (`"agent:"` prefix, `"global"` session keys) are
  structural and not user-configurable — no collision surface identified.

**Conclusion:** No additional gap found in this module.

## Selection

**Selected candidate: `src/config.zig` — Missing provider validation for named agents**

**Rationale:**
1. **Exact pattern match.** This is the actionable gap explicitly flagged in the
   bug-fix-patterns.md document itself.
2. **Lowest risk.** Additive-only change to config validation, not touching any
   security, gateway, or runtime code paths.
3. **Small fix.** ~15-20 lines of code.
4. **Clear test pattern.** Existing validation tests provide a template to follow.
5. **Real user impact.** Typos in provider names silently pass config validation
   and fail at runtime with unclear errors. Early validation matches the established
   principle: "Validation-at-load > fail-at-runtime."

**Not selected:**
- Candidate B (`agent_bindings_config.zig`) — depends on fixing config.zig first;
  the root gap is in `Config.validate()`.
- Candidate C (`agent_routing.zig`) — no additional gap found beyond the already-fixed
  "main" reserved ID check.
