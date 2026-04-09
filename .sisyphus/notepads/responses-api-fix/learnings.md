# Learnings — Responses API Fix

## convertToolsResponses (2026-04-09)
- OpenAI format uses nested `{"type":"function","function":{"name":...}}` wrapper
- Responses API format is flat: `{"type":"function","name":...,"description":...,"parameters":{...}}`
- `buildResponsesRequestBody` was incorrectly calling `convertToolsOpenAI` — produces wrong schema
- `buildChatCompletionRequestBody` MUST keep `convertToolsOpenAI` — only responses endpoint needs flat format
- Surgical fix: new function + one-line call site change, no refactoring needed
- Both `convertToolsOpenAI` and `convertToolsAnthropic` are well-tested patterns to copy from

## Zig 0.15.2 API Notes
- `ArrayListUnmanaged`: init with `.empty`, pass allocator to every method call
- `defer buf.deinit(alloc)` required for every ArrayListUnmanaged in tests
- `std.testing.expect(t0.get("function") == null)` works for verifying absent JSON keys
