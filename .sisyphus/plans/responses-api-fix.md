# Issue #773: Responses API Fix — Tool Schema + Null Error

## TL;DR

> **Quick Summary**: Fix two bugs in the OpenAI-compatible provider's Responses API (`api_mode=responses`) code path. Bug 1: tool definitions use nested Chat Completions format instead of flat Responses format. Bug 2: `"error": null` in response body is misclassified as an API error. Both are surgical fixes in 3 files.
>
> **Deliverables**:
> - `src/providers/helpers.zig` — new `convertToolsResponses()` (flat format)
> - `src/providers/compatible.zig` — wire `convertToolsResponses` into `buildResponsesRequestBody` (line 548)
> - `src/providers/error_classify.zig` — null guard in `classifyErrorObject()` (line 311-315)
> - 3 new tests + 1 updated existing test
>
> **Estimated Effort**: Short
> **Parallel Execution**: YES — 2 tasks in Wave 1, 1 task in Wave 2
> **Critical Path**: Task 1 + Task 2 → Task 3 (integration) → Final Verification

---

## Context

### Original Request
GitHub Issue #773: "bug: Responses API (api_mode=responses) broken — tool schema format and null error misclassification"

### Interview Summary
**Key Discussions**:
- Completed Sprint 1: 3 PRs opened (#786 trivial tests, #787 utility tests, #788 config validation fix)
- Strong in: test additions, config validation, provider code
- Surveyed 50 open issues, selected #773 (well-documented, in wheelhouse)
- Skipping #779 (shell tool docker error) for now
- Metis consultation confirmed: #773 first, self-contained, ~20 lines + 3 tests

**Research Findings** (ripgrep-verified):
- **Bug 1**: `compatible.zig:548` calls `root.convertToolsOpenAI()` → produces `{"type":"function","function":{"name":"..."}}` — Responses API needs `{"type":"function","name":"..."}`
- **Bug 2**: `error_classify.zig:315` — `if (err_value != .object) return .other;` — `.null` is not `.object`, returns `.other` (valid `ApiErrorKind`) → false error
- Zero `.null` handling exists in `error_classify.zig` or `compatible.zig`
- `convertToolsOpenAI` also used at lines 1720 and 1777 (Chat Completions) — those must NOT change
- Existing test at `compatible.zig:2545` only checks `"\"tools\""` presence, NOT format

### Metis Review
**Identified Gaps** (addressed):
- Bug 2 root cause is `classifyErrorObject()` line 315, not `parseResponsesResponse()`
- `convertToolsResponses` should be new function in `helpers.zig`, not inline
- Existing test doesn't validate format — need to add flat format assertions

---

## Work Objectives

### Core Objective
Fix two bugs in Responses API so tool-using requests work correctly and null error fields don't cause false error classification.

### Concrete Deliverables
- `src/providers/helpers.zig` — new `convertToolsResponses()` function
- `src/providers/compatible.zig` — wire `convertToolsResponses` at line 548, update test at line 2545
- `src/providers/error_classify.zig` — null guard at line 311-315

### Definition of Done
- [ ] `zig build test --summary all` → 0 failures, 0 leaks
- [ ] `zig build -Doptimize=ReleaseSmall` → compiles clean
- [ ] `zig fmt --check src/` → passes
- [ ] New test: `convertToolsResponses` produces flat format
- [ ] New test: `"error": null` does not trigger error classification
- [ ] Updated test: `buildResponsesRequestBody` tools assertion verifies flat format

### Must Have
- Flat tool schema: `{"type":"function","name":"...","description":"...","parameters":{...}}`
- Null guard: `if (err_value == .null) return null;` before `.object` check
- Tests following existing patterns

### Must NOT Have (Guardrails)
- Do NOT modify `convertToolsOpenAI` (helpers.zig:489-506)
- Do NOT modify `convertToolsAnthropic` (helpers.zig:510-527)
- Do NOT touch `buildChatCompletionRequestBody` (compatible.zig:1720, 1777)
- Do NOT modify `openai.zig` or `openrouter.zig` convertToolsOpenAI call sites
- Do NOT add new `ApiErrorKind` variants
- Do NOT modify `classifyTopLevelError`, `classifyFromFields`, `kindToError`
- No "while we're here" changes

---

## Verification Strategy

> **ZERO HUMAN INTERVENTION** — ALL verification is agent-executed.

### Test Decision
- **Infrastructure exists**: YES
- **Automated tests**: YES (TDD)
- **Framework**: `zig build test` with `std.testing.allocator`
- **If TDD**: RED (failing test) → GREEN (minimal impl) → REFACTOR

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start Immediately — 2 parallel tasks):
├── Task 1: convertToolsResponses + wire into buildResponsesRequestBody [quick]
└── Task 2: Null guard in classifyErrorObject [quick]

Wave 2 (After Wave 1 — integration + test update):
└── Task 3: Update existing test + integration test [quick]

Wave FINAL (After ALL tasks — 4 parallel reviews):
├── Task F1: Plan compliance audit (oracle)
├── Task F2: Code quality review (unspecified-high)
├── Task F3: Real manual QA (unspecified-high)
└── Task F4: Scope fidelity check (deep)
```

### Dependency Matrix
- **1**: — → 3
- **2**: — → 3
- **3**: 1, 2 → FINAL
- **FINAL**: 3 → user okay

### Agent Dispatch Summary
- **Wave 1**: **2** — T1 → `quick`, T2 → `quick`
- **Wave 2**: **1** — T3 → `quick`
- **FINAL**: **4** — F1 → `oracle`, F2 → `unspecified-high`, F3 → `unspecified-high`, F4 → `deep`

---

## TODOs

- [ ] 1. Add `convertToolsResponses` and wire into `buildResponsesRequestBody`

  **What to do**:
  1. In `src/providers/helpers.zig`, add `convertToolsResponses` after `convertToolsAnthropic` (after line 527). Format: `{"type":"function","name":"...","description":"...","parameters":{...}}` — flat, no nested `"function"` wrapper.
  2. In `src/providers/compatible.zig` line 548, change `root.convertToolsOpenAI` to `root.convertToolsResponses`.
  3. Add test `"convertToolsResponses produces flat format"` in `helpers.zig` — verify `"\"name\":\""` at top level, `"\"function\":{"` NOT present.

  **Must NOT do**:
  - Do NOT modify `convertToolsOpenAI` (helpers.zig:489-506)
  - Do NOT modify `convertToolsAnthropic` (helpers.zig:510-527)
  - Do NOT touch `buildChatCompletionRequestBody` (compatible.zig:1720, 1777)
  - Do NOT touch `openai.zig` or `openrouter.zig`

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: ~18 lines new code, exact parallel to existing `convertToolsOpenAI`
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Task 2)
  - **Parallel Group**: Wave 1 (with Task 2)
  - **Blocks**: Task 3
  - **Blocked By**: None

  **References**:
  - `src/providers/helpers.zig:489-506` — `convertToolsOpenAI` — copy structure, change format string from nested to flat
  - `src/providers/helpers.zig:510-527` — `convertToolsAnthropic` — structural reference
  - `src/providers/helpers.zig:592-633` — existing test patterns for convertTools functions
  - `src/providers/compatible.zig:548` — buggy call site: `try root.convertToolsOpenAI(&buf, allocator, tools)` — change to `convertToolsResponses`
  - OpenAI Responses API: https://platform.openai.com/docs/api-reference/responses/create — flat tool format

  **Acceptance Criteria**:
  - [ ] `convertToolsResponses` function exists in `helpers.zig`
  - [ ] `compatible.zig:548` uses `convertToolsResponses` not `convertToolsOpenAI`
  - [ ] `zig build test --summary all src/providers/helpers.zig` → 0 failures, 0 leaks

  **QA Scenarios**:

  ```
  Scenario: convertToolsResponses produces flat tool schema
    Tool: Bash (zig build test)
    Steps:
      1. Run: zig build test --summary all "convertToolsResponses produces flat format"
      2. Test creates ToolSpec{name="bash", description="Run shell", parameters_json="{}"}, serializes
      3. Parse output JSON, assert:
         - `items[0]["type"] == "function"`
         - `items[0]["name"] == "bash"` (top-level)
         - `items[0].get("function")` is null (key absent)
    Expected Result: Flat format confirmed, no "function" wrapper
    Evidence: .sisyphus/evidence/task-1-flat-schema.txt

  Scenario: No regression in existing convertTools tests
    Tool: Bash (zig build test)
    Steps:
      1. Run: zig build test --summary all "convertToolsOpenAI"
      2. Run: zig build test --summary all "convertToolsAnthropic"
      3. Verify: all existing tests pass, 0 leaks
    Expected Result: No regressions
    Evidence: .sisyphus/evidence/task-1-no-regression.txt
  ```

  **Commit**: YES
  - Message: `fix(providers): use flat tool schema for Responses API`
  - Files: `src/providers/helpers.zig`, `src/providers/compatible.zig`
  - Pre-commit: `zig build test --summary all`

- [ ] 2. Add null guard in `classifyErrorObject` for `"error": null`

  **What to do**:
  1. In `src/providers/error_classify.zig`, after line 311, add: `if (err_value == .null) return null;`
  2. Add test `"classifyErrorObject returns null for error:null"` — parse `{"error": null, "status": "ok"}`, verify `classifyKnownApiError` returns `null`.
  3. Add test `"parseResponsesResponse handles error:null"` in `compatible.zig` — parse `{"error": null, "output": [{"role":"assistant","content":[{"text":"Hello"}]}]}`, verify content extracted.

  **Must NOT do**:
  - Do NOT modify `classifyFromFields` (error_classify.zig:278-306)
  - Do NOT modify `classifyTopLevelError` (error_classify.zig:348-383)
  - Do NOT add new `ApiErrorKind` variants
  - Do NOT modify `kindToError` (error_classify.zig:10-18)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 1-line fix + 2 tests
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES (with Task 1)
  - **Parallel Group**: Wave 1 (with Task 1)
  - **Blocks**: Task 3
  - **Blocked By**: None

  **References**:
  - `src/providers/error_classify.zig:310-316` — `classifyErrorObject` — bug at line 315: `.null` falls through to `.other`
  - `src/providers/error_classify.zig:385-388` — `classifyKnownApiError` calls `classifyErrorObject` first
  - `src/providers/error_classify.zig:415-421` — existing test "classifyKnownApiError returns null for non-error payload" — pattern to follow
  - `src/providers/compatible.zig:717-766` — `parseResponsesResponse` calls `classifyKnownApiError` at line 724
  - `src/providers/compatible.zig:2639-2644` — existing test "parseResponsesResponse maps generic error envelope" — add null test adjacent

  **Acceptance Criteria**:
  - [ ] `error_classify.zig` has `if (err_value == .null) return null;` after line 311
  - [ ] `zig build test --summary all src/providers/error_classify.zig` → 0 failures, 0 leaks
  - [ ] New test: `"error": null` → `classifyKnownApiError` returns `null`

  **QA Scenarios**:

  ```
  Scenario: classifyKnownApiError returns null for "error": null
    Tool: Bash (zig build test)
    Steps:
      1. Run: zig build test --summary all "classifyErrorObject returns null for error:null"
      2. Input: `{"error": null, "status": "ok"}`
      3. Assert: classifyKnownApiError returns null
    Expected Result: Null error not classified as error
    Failure Indicators: Returns .other or any ApiErrorKind
    Evidence: .sisyphus/evidence/task-2-null-error.txt

  Scenario: parseResponsesResponse handles "error": null
    Tool: Bash (zig build test)
    Steps:
      1. Run: zig build test --summary all "parseResponsesResponse handles error:null"
      2. Input: `{"error": null, "output": [{"role":"assistant","content":[{"text":"Hello"}]}]}`
      3. Assert: content == "Hello", no error returned
    Expected Result: Response parsed despite null error
    Failure Indicators: error.OtherApiError or error.NoResponseContent
    Evidence: .sisyphus/evidence/task-2-responses-null-error.txt

  Scenario: No regression in existing error classification tests
    Tool: Bash (zig build test)
    Steps:
      1. Run: zig build test --summary all src/providers/error_classify.zig
      2. Verify: 0 failures, 0 leaks
    Expected Result: No regressions
    Evidence: .sisyphus/evidence/task-2-no-regression.txt
  ```

  **Commit**: YES
  - Message: `fix(providers): skip error classification for "error": null`
  - Files: `src/providers/error_classify.zig`, `src/providers/compatible.zig`
  - Pre-commit: `zig build test --summary all`

- [ ] 3. Update existing test + integration verification

  **What to do**:
  1. In `src/providers/compatible.zig:2573`, the existing test `"buildResponsesRequestBody includes tools and tool results"` only checks `"\"tools\""` presence. Add assertion: `try std.testing.expect(std.mem.indexOf(u8, body, "\"function\":{") == null);` — verify no nested wrapper in Responses API body.
  2. Run full test suite: `zig build test --summary all` → 0 failures, 0 leaks.
  3. Run `zig build -Doptimize=ReleaseSmall` → compiles clean.
  4. Run `zig fmt --check src/` → passes.

  **Must NOT do**:
  - Do NOT make any new production code changes

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Test-only assertion update + validation commands
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Sequential** (depends on Task 1 and Task 2)
  - **Blocks**: Final Verification Wave
  - **Blocked By**: Task 1, Task 2

  **References**:
  - `src/providers/compatible.zig:2545-2577` — existing test to update (line 2573 checks `"\"tools\""` only)
  - AGENTS.md §8 — Validation Matrix

  **Acceptance Criteria**:
  - [ ] Existing test has flat format assertion added
  - [ ] `zig build test --summary all` → 0 failures, 0 leaks
  - [ ] `zig build -Doptimize=ReleaseSmall` → compiles clean
  - [ ] `zig fmt --check src/` → passes

  **QA Scenarios**:

  ```
  Scenario: Updated test verifies flat format in Responses API body
    Tool: Bash (zig build test)
    Steps:
      1. Run: zig build test --summary all "buildResponsesRequestBody includes tools and tool results"
      2. Verify test passes with new flat format assertion
    Expected Result: Test passes, confirming flat format
    Evidence: .sisyphus/evidence/task-3-updated-test.txt

  Scenario: Full test suite passes
    Tool: Bash (zig build test)
    Steps:
      1. Run: zig build test --summary all
      2. Assert: 0 failures, 0 leaks
    Expected Result: All tests pass
    Evidence: .sisyphus/evidence/task-3-full-suite.txt

  Scenario: ReleaseSmall build compiles
    Tool: Bash
    Steps:
      1. Run: zig build -Doptimize=ReleaseSmall
      2. Assert: exit code 0
    Expected Result: Clean compilation
    Evidence: .sisyphus/evidence/task-3-release-build.txt
  ```

  **Commit**: YES (or squash into Task 1/2)
  - Message: `test(providers): verify flat format in Responses API tool test`
  - Files: `src/providers/compatible.zig`

---

## Final Verification Wave

> 4 review agents run in PARALLEL. ALL must APPROVE.

- [ ] F1. **Plan Compliance Audit** — `oracle`
  Verify: `convertToolsResponses` exists in `helpers.zig`, null guard in `error_classify.zig:312`, `compatible.zig:548` uses `convertToolsResponses`. For "Must NOT Have": `convertToolsOpenAI` untouched, `buildChatCompletionRequestBody` untouched, no new `ApiErrorKind`. Check evidence files.
  Output: `Must Have [3/3] | Must NOT Have [7/7] | VERDICT`

- [ ] F2. **Code Quality Review** — `unspecified-high`
  Run `zig build test --summary all` + `zig build -Doptimize=ReleaseSmall` + `zig fmt --check src/`. Check for AI slop, unused imports, `as any`.
  Output: `Build [PASS/FAIL] | Tests [N/N] | Format [PASS/FAIL] | VERDICT`

- [ ] F3. **Real Manual QA** — `unspecified-high`
  Execute ALL QA scenarios from ALL tasks. Verify flat format, null error handling, no regressions.
  Output: `Scenarios [N/N] | VERDICT`

- [ ] F4. **Scope Fidelity Check** — `deep`
  Verify each diff matches "What to do" exactly. No changes to `openai.zig`, `openrouter.zig`, `ollama.zig`, `convertToolsOpenAI`, `buildChatCompletionRequestBody`, `classifyTopLevelError`, `classifyFromFields`.
  Output: `Tasks [N/N] | Contamination [CLEAN/N] | VERDICT`

---

## Commit Strategy

- **1**: `fix(providers): use flat tool schema for Responses API` — `src/providers/helpers.zig`, `src/providers/compatible.zig`
- **2**: `fix(providers): skip error classification for "error": null` — `src/providers/error_classify.zig`, `src/providers/compatible.zig`
- **3**: `test(providers): verify flat format in Responses API tool test` — `src/providers/compatible.zig`

---

## Success Criteria

### Verification Commands
```bash
zig build test --summary all          # Expected: 0 failures, 0 leaks
zig build -Doptimize=ReleaseSmall     # Expected: compiles clean
zig fmt --check src/                  # Expected: no formatting issues
```

### Final Checklist
- [ ] `convertToolsResponses` exists, produces flat format
- [ ] `compatible.zig:548` uses `convertToolsResponses`
- [ ] `classifyErrorObject` returns null for `"error": null`
- [ ] 3+ new/updated tests
- [ ] No changes to `convertToolsOpenAI`, `convertToolsAnthropic`, `buildChatCompletionRequestBody`
- [ ] No changes to `classifyTopLevelError`, `classifyFromFields`, `kindToError`
- [ ] No changes to `openai.zig`, `openrouter.zig`, `ollama.zig`
