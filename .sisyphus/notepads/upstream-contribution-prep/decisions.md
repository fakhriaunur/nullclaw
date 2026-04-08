
## Task 14: Failing regression test for agent provider validation

- Added `UnknownAgentProvider` to `ValidationError` enum in `src/config.zig`
- Added test `"validation rejects named agent with unknown provider"` at end of file
- Test expects `validate()` to reject agents with provider names not in `self.providers`
- Currently fails (RED step) because `validate()` has no such check — proves bug exists
- Formatting passes (`zig fmt --check` clean)
- Build compiles clean
- Full test suite too slow to run locally (5600+ tests, large codebase)
- Next: Task 15 — implement the actual validation in `Config.validate()`
