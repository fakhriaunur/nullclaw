# Upstream Contribution Preparation — NullClaw

## TL;DR

> **Quick Summary**: Prepare a Zig beginner for effective upstream contribution to nullclaw — a 678 KB static binary AI assistant runtime with 5,640+ tests. Phase 0 builds Zig mental model, Phase 1 verifies environment, Phase 2a adds tests to 3 trivially small untested files as first PR, Phase 2b tests small utility functions, Phase 3 studies bug fix patterns, Phase 4 applies a regression test + fix.
>
> **Deliverables**:
> - Working dev environment with git hooks, baseline test pass
> - PR #1: Tests for version.zig, verbose.zig, web_search_providers/root.zig (3 atomic commits)
> - PR #2: Tests for search_base_url.zig, status.zig (2 atomic commits)
> - PR #3: Regression test + fix for a discovered bug pattern (2 atomic commits)
> - Documented understanding of VTable architecture ↔ DDD mapping
>
> **Estimated Effort**: Short-Medium (3-4 hours Phases 0-2a, 2-3 hours Phase 2b, 4-6 hours Phases 3-4)
> **Parallel Execution**: YES — within Phase 0 and Phase 1
> **Critical Path**: Phase 0 → Phase 1 → Phase 2a → Phase 2b → Phase 3 → Phase 4

---

## Context

### Original Request
"Let's prime our understanding about this repo for upstream contribution. Pay attention to CONTRIBUTING.md, AGENTS.md, CLAUDE.md, .github/ISSUE_TEMPLATE/, and any relevant docs about the codebase."

### Interview Summary
**Key Discussions**:
- **Contribution focus**: Bug fix / test coverage (safest entry point for beginners)
- **Zig experience**: Beginner (familiar with systems programming concepts)
- **Specificity**: Exploring — wants to learn codebase first, then decide
- **Additional request**: VTable patterns crash course with DDD correlation, then modular plan prioritizing first PR

**Research Findings**:
- **Metis analysis**: VTable dangling pointers (#1 footgun), memory leaks block push, Zig 0.15.2 API changes
- **TODO/FIXME scan**: Only 1 real TODO (JWT validation in gateway.zig — HIGH risk). Codebase is mature.
- **Untested files discovered** (from exploration agents):

| File | Lines | Priority | Notes |
|------|-------|----------|-------|
| `src/version.zig` | 3 | Phase 2a | build_options.version export — sanity check test |
| `src/verbose.zig` | 25 | Phase 2a | Thread-safe verbose flag — set/get/toggle tests |
| `src/tools/web_search_providers/root.zig` | 9 | Phase 2a | Module imports only — force-include test |
| `src/search_base_url.zig` | 63 | Phase 2b | URL validation/normalization — pure functions, excellent for testing |
| `src/status.zig` | 98 | Phase 2b | Status management — pure logic, clear error paths |
| `src/tools/web_search_providers/*.zig` | 53-204 | Deferred | HTTP providers — need mocking strategy |

- **Recent bug fixes**: 15 fixes in last 30 commits — key patterns: calculator precision (82240a8), config wiring (cfb6291, 38ee80f), provider handling (be0b18f, 03aa8bb)

### Metis Review
**Identified Gaps** (addressed):
- **CRITICAL FIX**: `thread_stacks.zig` was incorrectly listed as untested — removed from plan
- Added Phase 0 (Zig mental model for beginners) — essential before any code changes
- Added Phase 2b (small utility tests) — bridges trivial tests to bug fix work
- Split bug fix study into 3 concrete pattern studies (calculator, config, provider)
- All tasks reference actual files verified to exist and lack test coverage

---

## Work Objectives

### Core Objective
Get a Zig beginner from zero to first merged upstream PR in nullclaw, with a clear path to continued contribution.

### Concrete Deliverables
- Environment verified: Zig 0.15.2, git hooks, baseline tests pass
- PR #1: Tests for 3 trivially small untested files (version.zig, verbose.zig, web_search_providers/root.zig)
- PR #2: Tests for 2 small utility files (search_base_url.zig, status.zig)
- PR #3: Regression test + bug fix following a pattern from recent commits
- Draft notes: Zig patterns learned, build system understanding, bug fix catalog

### Definition of Done
- [ ] `zig build test --summary all` passes with 0 failures, 0 leaks
- [ ] `zig fmt --check src/` passes
- [ ] At least one PR opened (or ready to open) with passing CI
- [ ] Contributor understands VTable architecture and can independently extend a subsystem

### Must Have
- All test additions use `std.testing.allocator` (leak-detecting GPA)
- All tests are inline in the same source file (no separate test files)
- Git hooks enabled before any commit
- Each commit passes full test suite independently

### Must NOT Have (Guardrails)
- NO changes to security surfaces (security/, gateway.zig, runtime.zig)
- NO vtable interface changes (method signatures, struct layouts)
- NO config schema changes
- NO speculative abstractions or "while I'm here" refactoring
- NO modifications to more than one file per commit
- NO skipping `defer allocator.free()` on any allocation
- NO web search provider tests until HTTP mocking strategy is defined (Phase 5, deferred)

---

## Verification Strategy (MANDATORY)

> **ZERO HUMAN INTERVENTION** — ALL verification is agent-executed. No exceptions.

### Test Decision
- **Infrastructure exists**: YES — 5,640+ tests, GPA leak detection
- **Automated tests**: Tests-after (we're ADDING tests, not TDD for Phase 2; TDD for Phase 4)
- **Framework**: Zig built-in test runner (`zig build test`)
- **Agent-Executed QA**: ALWAYS (mandatory for all tasks)

### QA Policy
Every task MUST include agent-executed QA scenarios.

- **Test additions**: Use Bash (`zig build test --summary all`) — assert 0 failures, 0 leaks
- **Formatting**: Use Bash (`zig fmt --check src/`) — assert clean output
- **File verification**: Use Read tool — confirm test blocks exist, follow naming convention

---

## Execution Strategy

### Phase Execution Order

```
Phase 0 — Zig Mental Model (3 tasks, parallel):
├── Task 1: Error unions and defer patterns [quick]
├── Task 2: Allocator patterns (testing vs arena) [quick]
└── Task 3: builtin.is_test and side-effect guards [quick]

Phase 1 — Environment Setup (sequential after Phase 0):
└── Task 4: Verify Zig 0.15.2, enable hooks, baseline tests [quick]

Phase 2a — First PR: Trivial Test Additions (3 tasks, sequential for learning):
├── Task 5: Tests for version.zig (3 lines — sanity check) [quick]
├── Task 6: Tests for verbose.zig (25 lines — set/get cycle) [quick]
└── Task 7: Tests for web_search_providers/root.zig (9 lines — module imports) [quick]

Phase 2b — Second PR: Small Utility Tests (2 tasks, sequential):
├── Task 8: Tests for search_base_url.zig (63 lines — URL validation) [quick]
└── Task 9: Tests for status.zig (98 lines — status management) [quick]

Phase 3 — Bug Fix Pattern Study (3 tasks, parallel):
├── Task 10: Study calculator precision fix (commit 82240a8) [unspecified-low]
├── Task 11: Study config wiring fixes (commits cfb6291, 38ee80f) [unspecified-low]
└── Task 12: Study provider handling fixes (commits be0b18f, 03aa8bb) [unspecified-low]

Phase 4 — Bug Fix Application (3 tasks, sequential, TDD):
├── Task 13: Cross-reference patterns with untested files → select candidate [unspecified-low]
├── Task 14: Write FAILING regression test (TDD: RED step) [unspecified-low]
└── Task 15: Implement minimal fix (TDD: GREEN step) [unspecified-low]

Critical Path: Task 1/2/3 → Task 4 → Task 5 → Task 6 → Task 7 → PR #1 → Task 8 → Task 9 → PR #2 → Task 10/11/12 → Task 13 → Task 14 → Task 15 → PR #3
Parallel Speedup: ~35% faster than fully sequential
Max Concurrent: 3 (Phase 0 and Phase 3)
```

### Dependency Matrix

- **1-3**: - → 4 (Phase 0 parallel)
- **4**: 1, 2, 3 → 5, 6, 7
- **5**: 4 → Task 8 (sequential for learning feedback)
- **6**: 5 → Task 8
- **7**: 6 → 8, 10, 11, 12
- **8**: 7 → 9
- **9**: 8 → 10, 11, 12
- **10-12**: 9 → 13 (Phase 3 parallel)
- **13**: 10, 11, 12 → 14
- **14**: 13 → 15
- **15**: 14 → PR #3

### Agent Dispatch Summary

- **Phase 0**: 3 — T1 → `quick`, T2 → `quick`, T3 → `quick` (parallel)
- **Phase 1**: 1 — T4 → `quick`
- **Phase 2a**: 3 — T5 → `quick`, T6 → `quick`, T7 → `quick` (sequential for learning)
- **Phase 2b**: 2 — T8 → `quick`, T9 → `quick` (sequential)
- **Phase 3**: 3 — T10 → `unspecified-low`, T11 → `unspecified-low`, T12 → `unspecified-low` (parallel)
- **Phase 4**: 3 — T13 → `unspecified-low`, T14 → `unspecified-low`, T15 → `unspecified-low` (sequential)

---

## TODOs

> Implementation + Test = ONE Task. Never separate.
> EVERY task MUST have: Recommended Agent Profile + Parallelization info + QA Scenarios.

- [x] 1. Zig Mental Model: Error Unions and Defer Patterns

  **What to do**:
  - Study Zig error union patterns: `error!T`, `try`, `catch |err|`, `catch unreachable`
  - Study `defer` and `errdefer` — critical for leak-free tests
  - Find 3 examples in the codebase:
    - `src/config.zig` — arena allocator with defer deinit
    - `src/util.zig` — simple error return patterns
    - `src/providers/openai.zig` — try/catch in provider implementation
  - Copy pattern examples to `.sisyphus/drafts/zig-patterns.md` with one-line explanations
  - Focus on: when to use `try` vs `catch`, when `defer` is mandatory

  **Must NOT do**:
  - Do NOT modify any source files
  - Do NOT write any tests yet

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 2, 3)
  - **Parallel Group**: Phase 0 (with Tasks 2, 3)
  - **Blocks**: Task 4
  - **Blocked By**: None (can start immediately)

  **References**:
  - `src/config.zig` — ArenaAllocator with defer pattern
  - `src/util.zig` — Simple error return patterns
  - `CLAUDE.md:103-111` — Zig 0.15.2 API gotchas
  - `AGENTS.md:280-290` — Anti-patterns (do not skip defer allocator.free)

  **Acceptance Criteria**:
  - [ ] Notes file exists with 3+ copied pattern examples
  - [ ] Each pattern has one-line explanation in own words
  - [ ] Can distinguish: when to use `try` vs `catch |err|` vs `catch unreachable`

  **QA Scenarios**:

  ```
  Scenario: Zig pattern notes exist and are complete
    Tool: Read
    Steps:
      1. Read: .sisyphus/drafts/zig-patterns.md
      2. Assert: file contains at least 3 pattern examples with explanations
    Expected Result: Structured notes with error union and defer patterns
    Evidence: .sisyphus/evidence/task-1-zig-patterns.txt
  ```

  **Commit**: YES (groups with 2, 3)
  - Message: `chore: document Zig error union and defer patterns`

---

- [x] 2. Zig Mental Model: Allocator Patterns

  **What to do**:
  - Study `std.testing.allocator` — leak-detecting GPA, mandatory for all tests
  - Study `ArenaAllocator` — bulk cleanup pattern, used with `Config.load()` and complex tests
  - Understand the difference: `std.testing.allocator` = individual free required, `ArenaAllocator` = single deinit frees all
  - Find 2 examples in the codebase:
    - A test using `std.testing.allocator` directly
    - A test using `ArenaAllocator` with `defer arena.deinit()`
  - Document when to use which in `.sisyphus/drafts/zig-patterns.md`

  **Must NOT do**:
  - Do NOT modify any source files
  - Do NOT write any tests yet

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 1, 3)
  - **Parallel Group**: Phase 0 (with Tasks 1, 3)
  - **Blocks**: Task 4
  - **Blocked By**: None

  **References**:
  - `src/config.zig` — ArenaAllocator usage with Config.load()
  - `CLAUDE.md:92-99` — Config arena pattern example
  - `AGENTS.md:285` — "Do not skip defer allocator.free()"

  **Acceptance Criteria**:
  - [ ] Notes document: std.testing.allocator vs ArenaAllocator difference
  - [ ] Notes include 2 code examples with file:line references
  - [ ] Can explain: why Config.load() needs ArenaAllocator

  **QA Scenarios**:

  ```
  Scenario: Allocator notes exist and are complete
    Tool: Read
    Steps:
      1. Read: .sisyphus/drafts/zig-patterns.md
      2. Assert: file documents both allocator types with examples
    Expected Result: Clear allocator pattern documentation
    Evidence: .sisyphus/evidence/task-2-allocator-notes.txt
  ```

  **Commit**: YES (groups with 1, 3)
  - Message: `chore: document Zig allocator patterns`

---

- [x] 3. Zig Mental Model: builtin.is_test and Side-Effect Guards

  **What to do**:
  - Study `builtin.is_test` — how tests skip real network, processes, and hardware I/O
  - Find 3 examples across the codebase where `builtin.is_test` guards side effects:
    - `src/tools/browser.zig` or `src/tools/web_fetch.zig` — network call guards
    - `src/tools/shell.zig` — process spawn guards
    - Any provider with HTTP call guards
  - Document the pattern: `if (builtin.is_test) return mock_data;`
  - Add to `.sisyphus/drafts/zig-patterns.md`

  **Must NOT do**:
  - Do NOT modify any source files
  - Do NOT write any tests yet

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 1, 2)
  - **Parallel Group**: Phase 0 (with Tasks 1, 2)
  - **Blocks**: Task 4
  - **Blocked By**: None

  **References**:
  - `src/tools/browser.zig` or `src/tools/web_fetch.zig` — network guards
  - `src/tools/shell.zig` — process spawn guards
  - `AGENTS.md:99` — "builtin.is_test guards are acceptable to skip side effects"
  - `CLAUDE.md:116` — "Use builtin.is_test guards to skip side effects"

  **Acceptance Criteria**:
  - [ ] Notes include 3+ examples of builtin.is_test usage with file:line
  - [ ] Notes document the mock data return pattern
  - [ ] Can explain: why tests must not spawn real processes or open network connections

  **QA Scenarios**:

  ```
  Scenario: builtin.is_test notes exist and are complete
    Tool: Read
    Steps:
      1. Read: .sisyphus/drafts/zig-patterns.md
      2. Assert: file documents builtin.is_test pattern with 3+ examples
    Expected Result: Clear side-effect guard documentation
    Evidence: .sisyphus/evidence/task-3-builtin-notes.txt
  ```

  **Commit**: YES (groups with 1, 2)
  - Message: `chore: document builtin.is_test side-effect guard patterns`

---

- [x] 4. Environment Setup + Baseline Verification

  **What to do**:
  - Verify `zig version` outputs `0.15.2` exactly
  - Enable git hooks: `git config core.hooksPath .githooks`
  - Run `zig fmt --check src/` — confirm clean formatting
  - Run `zig build test --summary all` — record baseline (pass/fail count, leak status)
  - Save baseline results to notes

  **Must NOT do**:
  - Do NOT modify any source files
  - Do NOT skip hook verification
  - Do NOT proceed if `zig version` is not `0.15.2`

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO (blocks all subsequent tasks)
  - **Parallel Group**: Phase 1 (sequential after Phase 0)
  - **Blocks**: Tasks 5, 6, 7
  - **Blocked By**: Tasks 1, 2, 3

  **References**:
  - `AGENTS.md:257-269` — Git hooks setup and behavior
  - `CLAUDE.md:10-17` — Build & test commands
  - `CONTRIBUTING.md:55-66` — Git hooks documentation

  **Acceptance Criteria**:
  - [ ] `zig version` outputs `0.15.2`
  - [ ] `git config core.hooksPath` returns `.githooks`
  - [ ] `zig build test --summary all` completes with 0 failures, 0 leaks
  - [ ] `zig fmt --check src/` produces no output

  **QA Scenarios**:

  ```
  Scenario: Baseline test suite passes
    Tool: Bash
    Steps:
      1. Run: zig build test --summary all
      2. Assert: output contains "0 failed" and "0 leak"
      3. Capture: .sisyphus/evidence/task-4-baseline-test.txt
    Expected Result: All tests pass, 0 leaks detected
    Evidence: .sisyphus/evidence/task-4-baseline-test.txt

  Scenario: Git hooks are active
    Tool: Bash
    Steps:
      1. Run: git config core.hooksPath
      2. Assert: output equals ".githooks"
    Expected Result: Hooks path is configured
    Evidence: .sisyphus/evidence/task-4-hooks-config.txt

  Scenario: Zig version is correct
    Tool: Bash
    Steps:
      1. Run: zig version
      2. Assert: output equals "0.15.2"
    Expected Result: Exact version match
    Evidence: .sisyphus/evidence/task-4-zig-version.txt
  ```

  **Commit**: YES (groups with Phase 0 commits)
  - Message: `chore: verify environment and enable git hooks`

---

- [x] 5. Tests for version.zig (3 lines — sanity check)

  **What to do**:
  - Read `src/version.zig` — it exports `build_options.version` (comptime-injected by build.zig)
  - Add `test "version string is non-empty"` block inline in the file
  - Test: `version.string.len > 0` — a **sanity check** that build_options injection works
  - Do NOT assert a specific version value (e.g., "dev" or "2026.3.1") — the value is build-time dependent
  - Follow naming convention from zig-patterns notes (Tasks 1-3)
  - Validate: `zig build test --summary all` passes, `zig fmt --check src/` clean
  - Reference: `src/cron.zig` simple test pattern: `test "name" { try std.testing.expectEqual(...); }`

  **Must NOT do**:
  - Do NOT modify the version export logic
  - Do NOT assert a specific version value (build_options varies: "dev" locally, git tag in CI)
  - Do NOT add imports beyond what version.zig already has
  - Do NOT modify any other file

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 6, 7) — but for beginners, run sequentially 5→6→7 for learning feedback
  - **Parallel Group**: Phase 2a (with Tasks 6, 7)
  - **Blocks**: PR #1
  - **Blocked By**: Task 4

  **References**:
  - `src/version.zig` — Target file (3 lines, read before writing)
  - `.sisyphus/drafts/zig-patterns.md` — Zig patterns learned in Phase 0
  - `AGENTS.md:159-169` — Code naming contract (test names: space-separated phrases)
  - `CLAUDE.md:113-122` — Testing conventions (std.testing.allocator, builtin.is_test)

  **Acceptance Criteria**:
  - [ ] `src/version.zig` contains at least 1 `test "..."` block
  - [ ] Test verifies version string is non-empty (sanity check only)
  - [ ] `zig build test --summary all` passes (0 failures, 0 leaks)
  - [ ] `zig fmt --check src/version.zig` passes

  **QA Scenarios**:

  ```
  Scenario: version.zig tests pass
    Tool: Bash
    Steps:
      1. Run: zig build test --summary all 2>&1 | grep -E "(version|PASS|FAIL|leak)"
      2. Assert: version tests appear in output, 0 failures, 0 leaks
      3. Capture: .sisyphus/evidence/task-5-version-tests.txt
    Expected Result: version.zig tests pass with 0 leaks
    Evidence: .sisyphus/evidence/task-5-version-tests.txt

  Scenario: version.zig is properly formatted
    Tool: Bash
    Steps:
      1. Run: zig fmt --check src/version.zig
      2. Assert: no output (clean formatting)
    Expected Result: zig fmt reports no changes needed
    Evidence: .sisyphus/evidence/task-5-version-fmt.txt
  ```

  **Commit**: YES (commit 1 of 3 in PR #1)
  - Message: `test: add tests for version.zig`
  - Files: `src/version.zig`
  - Pre-commit: `zig fmt --check src/`

---

- [x] 6. Tests for verbose.zig (25 lines — thread-safe flag)

  **What to do**:
  - Read `src/verbose.zig` — understand the thread-safe verbose logging flag
  - Add test blocks inline:
    - `test "verbose flag defaults to false"` — verify initial state
    - `test "setVerbose enables verbose mode"` — verify set/get cycle
    - `test "toggleVerbose flips state"` — if toggle function exists
  - Use `std.testing.expect` for boolean assertions (no allocations needed)
  - Validate: `zig build test --summary all` passes, `zig fmt --check src/` clean

  **Must NOT do**:
  - Do NOT modify the verbose flag implementation
  - Do NOT add concurrency tests (overkill for this scope)
  - Do NOT modify any other file

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 5, 7) — but for beginners, run sequentially 5→6→7 for learning feedback
  - **Parallel Group**: Phase 2a (with Tasks 5, 7)
  - **Blocks**: PR #1
  - **Blocked By**: Tasks 4, 5

  **References**:
  - `src/verbose.zig` — Target file (25 lines, read before writing)
  - `.sisyphus/drafts/zig-patterns.md` — Test conventions from Phase 0
  - `AGENTS.md:159-169` — Naming contract

  **Acceptance Criteria**:
  - [ ] `src/verbose.zig` contains at least 2 `test "..."` blocks
  - [ ] Tests cover: default state, set/get cycle
  - [ ] `zig build test --summary all` passes (0 failures, 0 leaks)
  - [ ] `zig fmt --check src/verbose.zig` passes

  **QA Scenarios**:

  ```
  Scenario: verbose.zig tests pass
    Tool: Bash
    Steps:
      1. Run: zig build test --summary all 2>&1 | grep -E "(verbose|PASS|FAIL|leak)"
      2. Assert: verbose tests pass, 0 failures, 0 leaks
      3. Capture: .sisyphus/evidence/task-6-verbose-tests.txt
    Expected Result: verbose.zig tests pass with 0 leaks
    Evidence: .sisyphus/evidence/task-6-verbose-tests.txt

  Scenario: verbose.zig is properly formatted
    Tool: Bash
    Steps:
      1. Run: zig fmt --check src/verbose.zig
      2. Assert: no output
    Expected Result: Clean formatting
    Evidence: .sisyphus/evidence/task-6-verbose-fmt.txt
  ```

  **Commit**: YES (commit 2 of 3 in PR #1)
  - Message: `test: add tests for verbose.zig`
  - Files: `src/verbose.zig`
  - Pre-commit: `zig fmt --check src/`

---

- [x] 7. Tests for web_search_providers/root.zig (9 lines — module imports)

  **What to do**:
  - Read `src/tools/web_search_providers/root.zig` — it's 9 lines of module imports (brave, searxng, duckduckgo, etc.)
  - Add a force-include test block: `test { _ = @import("root.zig"); }` — ensures the module compiles during tests
  - This is a compilation gate test — verifies all 9 provider modules can be imported cleanly
  - No behavioral tests needed (individual providers are tested separately)
  - Validate: `zig build test --summary all` passes, `zig fmt --check src/` clean

  **Must NOT do**:
  - Do NOT test individual provider behavior (that requires HTTP mocking — deferred)
  - Do NOT modify any provider implementation files
  - Do NOT modify any other file

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 5, 6) — but for beginners, run sequentially 5→6→7 for learning feedback
  - **Parallel Group**: Phase 2a (with Tasks 5, 6)
  - **Blocks**: PR #1, Task 8
  - **Blocked By**: Tasks 4, 6

  **References**:
  - `src/tools/web_search_providers/root.zig` — Target file (9 lines of imports)
  - `.sisyphus/drafts/zig-patterns.md` — Test conventions from Phase 0
  - `AGENTS.md:159-169` — Naming contract

  **Acceptance Criteria**:
  - [ ] `src/tools/web_search_providers/root.zig` contains at least 1 `test "..."` block
  - [ ] Test is a force-include compilation gate (not behavioral)
  - [ ] `zig build test --summary all` passes (0 failures, 0 leaks)
  - [ ] `zig fmt --check src/tools/web_search_providers/root.zig` passes

  **QA Scenarios**:

  ```
  Scenario: web_search_providers/root.zig tests pass
    Tool: Bash
    Steps:
      1. Run: zig build test --summary all 2>&1 | grep -E "(web_search|PASS|FAIL|leak)"
      2. Assert: tests pass, 0 failures, 0 leaks
      3. Capture: .sisyphus/evidence/task-7-root-tests.txt
    Expected Result: root.zig tests pass with 0 leaks
    Evidence: .sisyphus/evidence/task-7-root-tests.txt

  Scenario: root.zig is properly formatted
    Tool: Bash
    Steps:
      1. Run: zig fmt --check src/tools/web_search_providers/root.zig
      2. Assert: no output
    Expected Result: Clean formatting
    Evidence: .sisyphus/evidence/task-7-root-fmt.txt
  ```

  **Commit**: YES (commit 3 of 3 in PR #1)
  - Message: `test: add tests for web_search_providers/root.zig`
  - Files: `src/tools/web_search_providers/root.zig`
  - Pre-commit: `zig fmt --check src/`

---

- [x] 8. Tests for search_base_url.zig (63 lines — URL validation)

  **What to do**:
  - Read `src/search_base_url.zig` — pure functions for URL validation and normalization
  - Functions: `isValid()`, `normalizeEndpoint()`, `validated()` (private)
  - Add test blocks inline covering:
    - `test "isValid accepts valid https URL"` — happy path
    - `test "isValid rejects empty string"` — edge case
    - `test "isValid rejects http for non-localhost"` — security constraint
    - `test "normalizeEndpoint appends /search when missing"` — normalization
    - `test "normalizeEndpoint returns error for invalid URL"` — error path
  - No allocations for isValid tests; normalizeEndpoint uses allocator.dupe — test with std.testing.allocator and verify no leaks
  - Validate: `zig build test --summary all` passes, `zig fmt --check src/` clean

  **Must NOT do**:
  - Do NOT modify the validation logic
  - Do NOT test internal `validated()` function directly (it's private)
  - Do NOT modify any other file

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Task 9) — but sequential 8→9 for learning
  - **Parallel Group**: Phase 2b (with Task 9)
  - **Blocks**: PR #2
  - **Blocked By**: Task 7

  **References**:
  - `src/search_base_url.zig` — Target file (63 lines, pure functions)
  - `.sisyphus/drafts/zig-patterns.md` — Allocator patterns from Phase 0
  - `src/net_security.zig` — isLocalHost function used by validation
  - `AGENTS.md:159-169` — Naming contract

  **Acceptance Criteria**:
  - [ ] `src/search_base_url.zig` contains at least 4 `test "..."` blocks
  - [ ] Tests cover: valid URL, empty input, http rejection, normalization, error path
  - [ ] `zig build test --summary all` passes (0 failures, 0 leaks)
  - [ ] `zig fmt --check src/search_base_url.zig` passes

  **QA Scenarios**:

  ```
  Scenario: search_base_url.zig tests pass
    Tool: Bash
    Steps:
      1. Run: zig build test --summary all 2>&1 | grep -E "(search_base|PASS|FAIL|leak)"
      2. Assert: tests pass, 0 failures, 0 leaks
      3. Capture: .sisyphus/evidence/task-8-search-tests.txt
    Expected Result: search_base_url.zig tests pass with 0 leaks
    Evidence: .sisyphus/evidence/task-8-search-tests.txt

  Scenario: search_base_url.zig is properly formatted
    Tool: Bash
    Steps:
      1. Run: zig fmt --check src/search_base_url.zig
      2. Assert: no output
    Expected Result: Clean formatting
    Evidence: .sisyphus/evidence/task-8-search-fmt.txt
  ```

  **Commit**: YES (commit 1 of 2 in PR #2)
  - Message: `test: add tests for search_base_url.zig`
  - Files: `src/search_base_url.zig`
  - Pre-commit: `zig fmt --check src/`

---

- [x] 9. Tests for status.zig (98 lines — status management)

  **What to do**:
  - Read `src/status.zig` — understand status management logic
  - Add test blocks inline covering core behaviors:
    - Status creation/initialization
    - Status transitions (if any state machine logic)
    - Error handling paths
  - Follow patterns from zig-patterns notes (Phase 0)
  - Validate: `zig build test --summary all` passes, `zig fmt --check src/` clean

  **Must NOT do**:
  - Do NOT modify the status logic
  - Do NOT add integration tests
  - Do NOT modify any other file

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Task 8) — but sequential 8→9 for learning
  - **Parallel Group**: Phase 2b (with Task 8)
  - **Blocks**: PR #2, Tasks 10-12
  - **Blocked By**: Tasks 7, 8

  **References**:
  - `src/status.zig` — Target file (98 lines)
  - `.sisyphus/drafts/zig-patterns.md` — Test conventions from Phase 0
  - `AGENTS.md:159-169` — Naming contract

  **Acceptance Criteria**:
  - [ ] `src/status.zig` contains at least 2 `test "..."` blocks
  - [ ] Tests cover: status creation, at least one transition or error path
  - [ ] `zig build test --summary all` passes (0 failures, 0 leaks)
  - [ ] `zig fmt --check src/status.zig` passes

  **QA Scenarios**:

  ```
  Scenario: status.zig tests pass
    Tool: Bash
    Steps:
      1. Run: zig build test --summary all 2>&1 | grep -E "(status|PASS|FAIL|leak)"
      2. Assert: tests pass, 0 failures, 0 leaks
      3. Capture: .sisyphus/evidence/task-9-status-tests.txt
    Expected Result: status.zig tests pass with 0 leaks
    Evidence: .sisyphus/evidence/task-9-status-tests.txt

  Scenario: status.zig is properly formatted
    Tool: Bash
    Steps:
      1. Run: zig fmt --check src/status.zig
      2. Assert: no output
    Expected Result: Clean formatting
    Evidence: .sisyphus/evidence/task-9-status-fmt.txt
  ```

  **Commit**: YES (commit 2 of 2 in PR #2)
  - Message: `test: add tests for status.zig`
  - Files: `src/status.zig`
  - Pre-commit: `zig fmt --check src/`

---

- [x] 10. Study Calculator Precision Fix Pattern

  **What to do**:
  - Read commit `82240a8` — calculator precision and output formatting fix
  - Understand the bug: large JSON integers (>2^53) lost precision when converted to f64; buffer overflows in string formatting
  - Understand the fix: added MAX_EXACT_INTEGER bounds check, dynamic allocation for formatting
  - Note the pattern: "numeric precision loss in JSON parsing" — check if similar issues exist in other tools
  - Document findings in `.sisyphus/drafts/bug-fix-patterns.md`

  **Must NOT do**:
  - Do NOT modify any source files
  - Do NOT fix anything yet

  **Recommended Agent Profile**:
  - **Category**: `unspecified-low`
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 11, 12)
  - **Parallel Group**: Phase 3 (with Tasks 11, 12)
  - **Blocks**: Task 13
  - **Blocked By**: Task 9

  **References**:
  - Commit `82240a8` — calculator precision fix
  - `src/tools/calculator.zig` — target file to study
  - `src/json_util.zig` — JSON parsing utilities

  **Acceptance Criteria**:
  - [ ] Bug fix pattern documented: root cause, fix approach, files changed
  - [ ] Notes identify whether similar precision issues may exist in other tools

  **QA Scenarios**:

  ```
  Scenario: Calculator fix pattern is documented
    Tool: Read
    Steps:
      1. Read: .sisyphus/drafts/bug-fix-patterns.md
      2. Assert: file contains calculator precision fix analysis
    Expected Result: Documented pattern with root cause and fix approach
    Evidence: .sisyphus/evidence/task-10-calc-pattern.txt
  ```

  **Commit**: YES (groups with 11, 12)
  - Message: `chore: document calculator precision fix pattern`

---

- [x] 11. Study Config Wiring Fix Pattern

  **What to do**:
  - Read commits `cfb6291` and `38ee80f` — config wiring and reserved agent ID fixes
  - Understand the bugs: config values not propagated to runtime behavior; named agent collision with reserved "main" routing
  - Understand the fixes: added wiring helpers, added validation for reserved identifiers
  - Note the pattern: "config field exists but not wired to runtime" — search for similar gaps
  - Document findings in `.sisyphus/drafts/bug-fix-patterns.md`

  **Must NOT do**:
  - Do NOT modify any source files
  - Do NOT fix anything yet

  **Recommended Agent Profile**:
  - **Category**: `unspecified-low`
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 10, 12)
  - **Parallel Group**: Phase 3 (with Tasks 10, 12)
  - **Blocks**: Task 13
  - **Blocked By**: Task 9

  **References**:
  - Commits `cfb6291`, `38ee80f` — config wiring fixes
  - `src/config.zig` — config loading and wiring
  - `src/config_types.zig` — config type definitions

  **Acceptance Criteria**:
  - [ ] Bug fix pattern documented: root cause, fix approach, files changed
  - [ ] Notes identify whether similar config wiring gaps may exist

  **QA Scenarios**:

  ```
  Scenario: Config wiring fix pattern is documented
    Tool: Read
    Steps:
      1. Read: .sisyphus/drafts/bug-fix-patterns.md
      2. Assert: file contains config wiring fix analysis
    Expected Result: Documented pattern with root cause and fix approach
    Evidence: .sisyphus/evidence/task-11-config-pattern.txt
  ```

  **Commit**: YES (groups with 10, 12)
  - Message: `chore: document config wiring fix pattern`

---

- [x] 12. Study Provider Handling Fix Pattern

  **What to do**:
  - Read commits `be0b18f` and `03aa8bb` — versionless custom provider handling and gemini-cli ACP handshake
  - Understand the bugs: provider initialization failures with edge cases (missing version, handshake parsing)
  - Understand the fixes: robust parsing, graceful fallbacks
  - Note the pattern: "provider initialization edge cases" — check if similar issues exist in other providers
  - Document findings in `.sisyphus/drafts/bug-fix-patterns.md`

  **Must NOT do**:
  - Do NOT modify any source files
  - Do NOT fix anything yet

  **Recommended Agent Profile**:
  - **Category**: `unspecified-low`
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Tasks 10, 11)
  - **Parallel Group**: Phase 3 (with Tasks 10, 11)
  - **Blocks**: Task 13
  - **Blocked By**: Task 9

  **References**:
  - Commits `be0b18f`, `03aa8bb` — provider handling fixes
  - `src/providers/` — provider implementations
  - `src/providers/factory.zig` — provider factory logic

  **Acceptance Criteria**:
  - [ ] Bug fix pattern documented: root cause, fix approach, files changed
  - [ ] Notes identify whether similar provider edge cases may exist

  **QA Scenarios**:

  ```
  Scenario: Provider handling fix pattern is documented
    Tool: Read
    Steps:
      1. Read: .sisyphus/drafts/bug-fix-patterns.md
      2. Assert: file contains provider handling fix analysis
    Expected Result: Documented pattern with root cause and fix approach
    Evidence: .sisyphus/evidence/task-12-provider-pattern.txt
  ```

  **Commit**: YES (groups with 10, 11)
  - Message: `chore: document provider handling fix pattern`

---

- [x] 13. Cross-Reference Patterns with Untested Files → Select Candidate

  **What to do**:
  - Review bug fix patterns from Tasks 10-12
  - Cross-reference with untested files:
    - `src/search_base_url.zig` — URL validation (may have edge cases like provider handshake)
    - `src/status.zig` — status management (may have config wiring gaps)
    - Any other small untested file
  - Select ONE candidate file that shares a bug pattern
  - Verify the fix would be straightforward (<20 lines of code change)
  - Document selection in `.sisyphus/drafts/bug-fix-selection.md`

  **Must NOT do**:
  - Do NOT write tests yet (that's Task 14)
  - Do NOT fix anything yet (that's Task 15)
  - Do NOT select HIGH-risk files (security/, gateway.zig, runtime.zig)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-low`
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO (depends on Tasks 10-12)
  - **Parallel Group**: Phase 4 (sequential start)
  - **Blocks**: Task 14
  - **Blocked By**: Tasks 10, 11, 12

  **References**:
  - `.sisyphus/drafts/bug-fix-patterns.md` — Patterns from Phase 3
  - `src/search_base_url.zig` — Candidate: URL validation edge cases
  - `src/status.zig` — Candidate: status management

  **Acceptance Criteria**:
  - [ ] ONE candidate file selected with rationale linking to a specific bug pattern
  - [ ] Candidate confirmed as LOW risk (not security, gateway, runtime)
  - [ ] Fix estimated at <20 lines of code change
  - [ ] Selection documented in `.sisyphus/drafts/bug-fix-selection.md`

  **QA Scenarios**:

  ```
  Scenario: Candidate selection exists with rationale
    Tool: Read
    Steps:
      1. Read: .sisyphus/drafts/bug-fix-selection.md
      2. Assert: file identifies candidate file, links to bug pattern, confirms LOW risk
    Expected Result: Clear candidate selection with justification
    Evidence: .sisyphus/evidence/task-13-selection.txt
  ```

  **Commit**: YES (groups with Phase 4 commits)
  - Message: `chore: select bug fix candidate from pattern analysis`

---

- [x] 14. Write FAILING Regression Test (TDD: RED Step)

  **What to do**:
  - Based on selected candidate from Task 13, write a test that FAILS before the fix
  - Add test block inline in the source file
  - Test must reproduce the exact bug pattern (e.g., missing edge case, unhandled input)
  - Run tests to CONFIRM it fails — this is the RED step of TDD
  - Add comment citing the bug pattern being guarded against (per AGENTS.md §8.1)
  - DO NOT fix the bug yet — commit the failing test separately

  **Must NOT do**:
  - Do NOT fix the bug (that's Task 15)
  - Do NOT modify any other file
  - Do NOT skip the "confirm it fails" step

  **Recommended Agent Profile**:
  - **Category**: `unspecified-low`
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO (depends on Task 13)
  - **Parallel Group**: Phase 4 (sequential after Task 13)
  - **Blocks**: Task 15
  - **Blocked By**: Task 13

  **References**:
  - Selected candidate file from Task 13
  - `.sisyphus/drafts/zig-patterns.md` — Test conventions from Phase 0
  - `.sisyphus/drafts/bug-fix-patterns.md` — Bug pattern to reproduce
  - `AGENTS.md:237-252` — Test coverage mandate, regression comment format

  **Acceptance Criteria**:
  - [ ] Test block added inline in candidate source file
  - [ ] Test FAILS when run (confirm the bug exists)
  - [ ] Test includes comment citing the bug pattern being guarded
  - [ ] `zig fmt --check src/<file>.zig` passes

  **QA Scenarios**:

  ```
  Scenario: Regression test fails as expected (RED step)
    Tool: Bash
    Steps:
      1. Run: zig build test --summary all 2>&1
      2. Assert: test output shows the new test FAILING
      3. Capture: .sisyphus/evidence/task-14-test-fails.txt
    Expected Result: Test fails, confirming the bug exists
    Failure Indicators: Test passes (bug doesn't exist, or test is wrong)
    Evidence: .sisyphus/evidence/task-14-test-fails.txt

  Scenario: Test file is properly formatted
    Tool: Bash
    Steps:
      1. Run: zig fmt --check src/<candidate-file>.zig
      2. Assert: no output
    Expected Result: Clean formatting
    Evidence: .sisyphus/evidence/task-14-fmt.txt
  ```

  **Commit**: YES (commit 1 of 2 in PR #3)
  - Message: `test: add regression test for [bug description]`
  - Files: `src/<candidate-file>.zig`
  - Pre-commit: `zig fmt --check src/`
  - Note: This commit should have a FAILING test (will be fixed in next commit)

---

- [x] 15. Implement Minimal Fix (TDD: GREEN Step)

  **What to do**:
  - Implement the MINIMAL fix to make the regression test from Task 14 pass
  - Follow KISS/YAGNI principles — only fix the specific issue, no refactoring
  - Apply proper patterns from the bug fix catalog (Tasks 10-12)
  - Run `zig build test --summary all` — ALL tests must pass (0 failures, 0 leaks)
  - Run `zig fmt --check src/` — must be clean
  - Add regression comment per AGENTS.md §8.1 format: `// Regression: [description]`
  - Optional: run `zig build -Doptimize=ReleaseSmall` to verify no binary size regression

  **Must NOT do**:
  - Do NOT refactor surrounding code
  - Do NOT fix other issues "while here"
  - Do NOT add speculative error handling
  - Do NOT modify files outside the candidate

  **Recommended Agent Profile**:
  - **Category**: `unspecified-low`
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO (depends on Task 14)
  - **Parallel Group**: Phase 4 (final task, after Task 14)
  - **Blocks**: PR #3
  - **Blocked By**: Task 14

  **References**:
  - Selected candidate file + failing test from Task 14
  - Similar fix from bug fix pattern (Tasks 10-12) — follow the same pattern
  - `AGENTS.md:237-252` — Test coverage mandate, regression comment format
  - `AGENTS.md:73-114` — Engineering principles (KISS, YAGNI, Fail Fast)

  **Acceptance Criteria**:
  - [ ] Minimal fix applied — only changes necessary to pass the regression test
  - [ ] `zig build test --summary all` passes (0 failures, 0 leaks)
  - [ ] `zig fmt --check src/` passes
  - [ ] Source file includes regression comment: `// Regression: [description of bug pattern]`
  - [ ] No other files modified
  - [ ] Optional: `zig build -Doptimize=ReleaseSmall` compiles clean

  **QA Scenarios**:

  ```
  Scenario: All tests pass after fix (GREEN step)
    Tool: Bash
    Steps:
      1. Run: zig build test --summary all
      2. Assert: 0 failures, 0 leaks
      3. Assert: previously failing test now passes
      4. Capture: .sisyphus/evidence/task-15-all-tests-pass.txt
    Expected Result: Full test suite passes, regression test green
    Evidence: .sisyphus/evidence/task-15-all-tests-pass.txt

  Scenario: Fix is minimal — only candidate file changed
    Tool: Bash
    Steps:
      1. Run: git diff --name-only HEAD~1
      2. Assert: only src/<candidate-file>.zig appears
    Expected Result: Single file changed
    Evidence: .sisyphus/evidence/task-15-diff-scope.txt

  Scenario: Formatting is clean
    Tool: Bash
    Steps:
      1. Run: zig fmt --check src/
      2. Assert: no output
    Expected Result: Clean formatting across all source
    Evidence: .sisyphus/evidence/task-15-fmt.txt
  ```

  **Commit**: YES (commit 2 of 2 in PR #3)
  - Message: `fix: [bug description] — [brief fix description]`
  - Files: `src/<candidate-file>.zig`
  - Pre-commit: `zig fmt --check src/`, `zig build test --summary all`

---

## Final Verification Wave (MANDATORY — after ALL implementation tasks)

> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit "okay" before completing.

- [ ] F1. **Plan Compliance Audit** — `oracle`
  Read the plan end-to-end. For each "Must Have": verify implementation exists. For each "Must NOT Have": search codebase for forbidden patterns. Check evidence files exist in .sisyphus/evidence/. Compare deliverables against plan.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [ ] F2. **Code Quality Review** — `unspecified-high`
  Run `zig build test --summary all` + `zig fmt --check src/`. Review all changed files for: missing defer free, non-standard test names, missing regression comments, unsafe patterns.
  Output: `Build [PASS/FAIL] | Tests [N pass/N fail] | Files [N clean/N issues] | VERDICT`

- [ ] F3. **Real Manual QA** — `unspecified-high`
  Start from clean state. Execute EVERY QA scenario from EVERY task — follow exact steps, capture evidence. Save to `.sisyphus/evidence/final-qa/`.
  Output: `Scenarios [N/N pass] | VERDICT`

- [ ] F4. **Scope Fidelity Check** — `deep`
  For each task: read "What to do", read actual diff. Verify 1:1 — everything in spec was built (no missing), nothing beyond spec was built (no creep). Check "Must NOT do" compliance.
  Output: `Tasks [N/N compliant] | VERDICT`

---

## Commit Strategy

### Phase 0 + 1: Setup (4 commits)
- 1: `chore: document Zig error union and defer patterns` — notes file
- 2: `chore: document Zig allocator patterns` — notes file
- 3: `chore: document builtin.is_test side-effect guard patterns` — notes file
- 4: `chore: verify environment and enable git hooks` — baseline evidence files

### Phase 2a: First PR (3 commits → 1 PR)
- 5: `test: add tests for version.zig` — only `src/version.zig`
- 6: `test: add tests for verbose.zig` — only `src/verbose.zig`
- 7: `test: add tests for web_search_providers/root.zig` — only `src/tools/web_search_providers/root.zig`

### Phase 2b: Second PR (2 commits → 1 PR)
- 8: `test: add tests for search_base_url.zig` — only `src/search_base_url.zig`
- 9: `test: add tests for status.zig` — only `src/status.zig`

### Phase 3: Pattern Study (3 commits)
- 10: `chore: document calculator precision fix pattern` — notes file
- 11: `chore: document config wiring fix pattern` — notes file
- 12: `chore: document provider handling fix pattern` — notes file

### Phase 4: Bug Fix PR (2 commits → 1 PR)
- 13: `chore: select bug fix candidate from pattern analysis` — notes file
- 14: `test: add regression test for [bug description]` — only candidate source file (FAILING test)
- 15: `fix: [bug description] — [brief fix description]` — only candidate source file (test now passes)

### Per-Commit Validation (MANDATORY):
- After EVERY commit: `zig build test --summary all` must pass (except commit 14 — intentionally failing)
- After EVERY commit: `zig fmt --check src/` must pass

---

## Success Criteria

### Verification Commands
```bash
zig version                          # Expected: 0.15.2
git config core.hooksPath            # Expected: .githooks
zig build test --summary all         # Expected: 0 failed, 0 leaks
zig fmt --check src/                 # Expected: no output
```

### Final Checklist
- [ ] All "Must Have" present (std.testing.allocator, inline tests, git hooks)
- [ ] All "Must NOT Have" absent (no security changes, no vtable changes, no config schema changes)
- [ ] All tests pass (0 failures, 0 leaks)
- [ ] At least 1 PR opened or ready to open
- [ ] Contributor understands VTable architecture ↔ DDD mapping
- [ ] Contributor can independently extend a subsystem (add provider/channel/tool)
