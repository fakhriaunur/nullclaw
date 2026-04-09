# Zig 0.15.2 Knowledge Base

> Compiled from langref, stdlib source (Codeberg 0.15.2), and nullclaw codebase patterns.
> Updated: 2026-04-08

---

## 1. Core Language (Langref — Confirmed)

### Types
| Type | Syntax | Notes |
|------|--------|-------|
| Integers | `i8`, `u32`, `comptime_int` | Twos-complement wrapping with `%` operators (`+%`, `-%`, `*%`) |
| Floats | `f16`, `f32`, `f64`, `f128` | `/` and `%` on floats can Division by Zero in Optimized mode |
| Slices | `[]T`, `[]const T` | Fat pointer (data ptr + len). Bounds-checked. |
| Arrays | `[N]T` | Compile-time known length. `array.len` is comptime. |
| Pointers | `*T` (single), `[*]T` (many), `*[N]T` (array) | `*T` = deref with `.*`, no arithmetic. `[*]T` = index + arithmetic. |
| Sentinels | `[N:0]u8`, `[:0]T` | Guarantees sentinel at `len` index. `array[0..runtime_len :0]` safety-checked. |
| Enums | `enum { a, b, c }` | Can be cast to/from int with `@intFromEnum` / `@enumFromInt` |
| Structs | `struct { x: f32, y: f32 }` | No field order guarantees. ABI-aligned. |
| Unions | `union(enum) { a: i32, b: f32 }` | Tagged unions auto-discriminate. Untagged = raw bits. |
| Optionals | `?T` | `orelse` for default, `if (x) |v|` for unwrap, `x.?` for panic-on-null |
| Error unions | `error!T` | `try`, `catch |err|`, `catch unreachable` |

### Error Handling
```zig
// try — propagate upward (80% of cases)
const result = try doThing();

// catch with switch — handle specific errors
const file = open() catch |err| switch (err) {
    error.FileNotFound => return null,
    else => return err,
};

// catch with block — degrade gracefully
const resp = fetch() catch |err| {
    log.err("failed: {}", .{err});
    return fallback;
};

// catch unreachable — document why it can't fail
const val = maybeNull orelse unreachable;
```

### Defer Patterns
```zig
// defer — runs on ALL exits (success or error)
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

// errdefer — runs ONLY on error exits
const buf = try allocator.alloc(u8, 100);
errdefer allocator.free(buf);
// ... do things that might fail ...
```

### Slices — Key Rules
- `&slice[0]` — asserts `len > 0`, panics if empty
- `slice.ptr` — gives `[*]T`, NO assertion, safe on empty slices
- `array[runtime_start..]` — converts array to slice
- `array[runtime_start..][0..length]` — two-step slice to get compile-time known length
- Empty slice: `&.{}` or `&[0]u8{}`
- Slicing a pointer: `ptr[start..end]` where ptr is `*[N]T`

### Comptime
- `comptime var` — mutable at compile time
- `comptime T: type` — type parameter
- `inline for` — unrolls loop at compile time (requires comptime-known array)
- `@TypeOf(x)` — get the type of x at comptime
- `@hasDecl(T, "name")` — check if type has a declaration
- `@hasField(T, "name")` — check if struct has a field

---

## 2. stdlib Modules (Confirmed from Source)

### 2.1 `std.ArrayList` (formerly ArrayListUnmanaged)

**IMPORTANT**: In 0.15.2, `ArrayListUnmanaged` is now a **deprecated alias** for `ArrayList`.

```zig
// Initialization
var list = std.ArrayListUnmanaged(u8).empty;  // still works (deprecated alias)
var list: std.ArrayListUnmanaged(u8) = .empty;

// All methods require explicit allocator
try list.append(allocator, item);
try list.appendSlice(allocator, items);
try list.ensureUnusedCapacity(allocator, 10);

// Cleanup
defer list.deinit(allocator);

// Get owned slice (transfers ownership, list is undefined after)
const owned = try list.toOwnedSlice(allocator);
```

**DEPRECATED** (AGENTS.md §10):
- `ArrayListUnmanaged.writer()` as `?*Io.Writer` — incompatible types, deprecated with no replacement

### 2.2 `std.Io` (The New I/O Layer)

`std.io` is deprecated. `std.Io` is the primary namespace.

```zig
// Reader — replaces GenericReader, AnyReader, FixedBufferStream
pub const Reader = @import("Io/Reader.zig");

// Writer — replaces GenericWriter, AnyWriter
pub const Writer = @import("Io/Writer.zig");

// Limit — for bounded I/O
pub const Limit = enum(usize) {
    nothing = 0,
    unlimited = std.math.maxInt(usize),
    _,
};

// Deprecated (no replacement):
// - CountingReader
// - FixedBufferStream (use Reader directly)
// - AnyReader / AnyWriter
// - null_writer (use Writer.Discarding)
```

### 2.3 `std.testing`

```zig
// The allocator — leak-detecting GPA, ONLY for tests
const allocator = std.testing.allocator;
// If you forget to free, the test suite reports a leak.

// Assertions
try std.testing.expect(bool);                          // basic check
try std.testing.expectEqual(expected, actual);         // peer type resolution
try std.testing.expectEqualStrings(expected, actual);  // string diff output
try std.testing.expectEqualSlices(T, expected, actual);// slice diff with index
try std.testing.expectError(expected_error, union);    // error union check
try std.testing.expectApproxEqAbs(expected, actual, tolerance); // float
try std.testing.expectApproxEqRel(expected, actual, tolerance); // float

// Temp directories
var tmp = std.testing.tmpDir(.{});
defer tmp.cleanup();
const dir = tmp.dir;
// Creates in .zig-cache/tmp/ with random sub-path

// Formatting
try std.testing.expectFmt("expected", "template {s}", .{arg});

// String checks
try std.testing.expectStringStartsWith(actual, prefix);
try std.testing.expectStringEndsWith(actual, suffix);

// Failing allocator — for testing OOM paths
// std.testing.failing_allocator
```

### 2.4 `std.heap`

```zig
// ArenaAllocator — bulk allocation, single deinit
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const alloc = arena.allocator();

// GeneralPurposeAllocator — leak detection
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();  // panics on leak
const alloc = gpa.allocator();

// FixedBufferAllocator — zero-allocation from a buffer
var fba = std.heap.FixedBufferAllocator.init(buffer);
const alloc = fba.allocator();

// Allocator interface
const bytes = try allocator.alloc(u8, 100);
defer allocator.free(bytes);
const duped = try allocator.dupe(u8, source);
defer allocator.free(duped);
```

### 2.5 `std.mem`

```zig
// Comparison
std.mem.eql(u8, a, b);           // slice equality
std.mem.startsWith(u8, s, prefix);
std.mem.endsWith(u8, s, suffix);
std.mem.indexOfDiff(u8, actual, expected); // find first difference

// Copying
@memcpy(dest, src);              // comptime-known length
std.mem.copyForwards(u8, dest, src); // runtime-known
std.mem.copyBackwards(u8, dest, src);

// Filling
@memset(ptr, value);             // comptime-known length
std.mem.set(u8, slice, value);   // runtime-known

// Trimming
std.mem.trim(u8, slice, chars_to_trim);
std.mem.trimLeft(u8, slice, chars);
std.mem.trimRight(u8, slice, chars);

// Alignment
std.mem.alignForward(usize, value, alignment);
std.mem.alignBackward(usize, value, alignment);

// Byte-to-slice
std.mem.bytesAsSlice(u32, bytes[0..]);

// Windows
std.mem.window(u8, slice, step, max_len); // sliding window iterator
```

### 2.6 `std.fs`

```zig
// Current directory
const cwd = std.fs.cwd();

// File operations
const file = try cwd.createFile("path.txt", .{});
defer file.close();
try file.writeAll("content");

const file = try cwd.openFile("path.txt", .{});
defer file.close();
const bytes = try file.readToEndAlloc(allocator, max_bytes);
defer allocator.free(bytes);

// stdout (NOT std.io.getStdOut() — doesn't exist in 0.15!)
const stdout = std.fs.File.stdout();

// Paths
std.fs.path.join(allocator, &.{ "a", "b", "c" });
std.fs.path.dirname(path);
std.fs.path.basename(path);

// Temp directory access via std.testing.tmpDir()
```

### 2.7 `std.process`

```zig
// Child process
var child = std.process.Child.init(&.{ "cmd", "arg1", "arg2" }, allocator);
child.stdout_behavior = .Pipe;  // capitalized!
child.stderr_behavior = .Pipe;
const term = try child.spawnAndWait();
```

### 2.8 `std.fmt`

```zig
// Format to buffer
var buf: [64]u8 = undefined;
const result = try std.fmt.bufPrint(&buf, "hello {s}", .{"world"});

// Format with allocation
const result = try std.fmt.allocPrint(allocator, "hello {s}", .{"world"});
defer allocator.free(result);

// Count bytes needed
const len = std.fmt.count("hello {s}", .{"world"});

// Common format specifiers
// {s} — string (slice)
// {d} — decimal integer
// {X} — hex uppercase
// {X:0>2} — zero-padded hex
// {any} — any type (auto-formatted)
// {*} — pointer address
// {c} — character
```

### 2.9 `std.http` (Confirmed via Context7)

```zig
// HTTP client
var client = std.http.Client{ .allocator = allocator };
defer client.deinit();

var request = try client.open(.GET, try std.Uri.parse("https://example.com"), .{});
defer request.deinit();
try request.send();
try request.wait();

// Note: nullclaw uses curl subprocess for HTTP, NOT std.http.Client
// because of known segfaults in Zig 0.15's HTTP client
```

### 2.10 `std.crypto`

```zig
// ChaCha20Poly1305 — AGENTS.md WARNING:
// heap-allocated output buffer SEGFAULTS on tag failure (macOS/Zig 0.15)
// Use stack buffer + allocator.dupe() instead:
var tag: [16]u8 = undefined;
var nonce: [12]u8 = undefined;
var key: [32]u8 = undefined;
// ... populate ...

// Encrypt to stack buffer, then dupe if needed
var ciphertext_buf: [1024]u8 = undefined;
const ct = try std.crypto.aead.chacha_poly.encrypt(&ciphertext_buf, plaintext, &key, &nonce, &.{}, &tag);
const owned_ct = try allocator.dupe(u8, ct);

// For decrypt: use stack buffer, NEVER heap output
var plaintext_buf: [1024]u8 = undefined;
const pt = std.crypto.aead.chacha_poly.decrypt(&plaintext_buf, ciphertext, &key, &nonce, &.{}, &tag) catch |err| {
    // tag failure = auth failed, do NOT use plaintext_buf
    return err;
};
```

### 2.10 `std.json`

NullClaw uses its own `json_util` and `json_parse` layers, not `std.json` directly. The stdlib `std.json` is available but the project prefers custom parsing for performance and size control.

### 2.12 `std.Uri`

```zig
// Parse a URI
const uri = try std.Uri.parse(url);
uri.scheme;    // "https"
uri.host;      // "example.com"
uri.path;      // .raw for raw path bytes

// In nullclaw: search_base_url.zig uses this for URL validation
```

---

## 3. Zig 0.15.2 API Gotchas (From AGENTS.md + Experience)

| Old API | New API (0.15.2) | Notes |
|---------|-----------------|-------|
| `std.io.getStdOut()` | `std.fs.File.stdout()` | Old doesn't exist |
| `std.io.Writer` | `std.Io.Writer` | Capital Io |
| `GenericWriter` | `Io.Writer` | Deprecated |
| `ArrayListUnmanaged` | `ArrayList` | Deprecated alias |
| `.pipe` | `.Pipe` | Capitalized for ChildProcess |
| `std.io.getStdOut().writer().print()` | `std.fs.File.stdout().writer(&buf).interface.print()` | New writer pattern |

---

## 4. NullClaw-Specific Patterns

### Config Loading Pattern
```zig
var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
defer arena.deinit();
var cfg = try Config.load(arena.allocator());
defer cfg.deinit();
```

### VTable Implementation Pattern
```zig
pub const SomeProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
};

pub const VTable = struct {
    chatWithSystem: *const fn (ptr: *anyopaque, request: ChatRequest, allocator: Allocator) anyerror!ChatResponse,
    chat: *const fn (ptr: *anyopaque, request: ChatRequest, allocator: Allocator) anyerror!ChatResponse,
    supportsNativeTools: *const fn (ptr: *anyopaque) bool,
    getName: *const fn (ptr: *anyopaque) []const u8,
    deinit: *const fn (ptr: *anyopaque, allocator: Allocator) void,
};
```

### builtin.is_test Guard Pattern
```zig
if (builtin.is_test) {
    return allocator.dupe(u8, "test-mock-response") catch unreachable;
}
// Real implementation below...
```

### Test Naming Convention
```zig
test "command risk low for read commands" {
    // Space-separated descriptive phrases
}
```

---

## 5. Build System (build.zig)

```bash
zig build                                    # dev build
zig build -Doptimize=ReleaseSmall            # release (< 1 MB target)
zig build test --summary all                 # all tests
zig build -Dchannels=telegram,cli            # selective channel compilation
zig build -Dengines=base,sqlite              # selective memory engines
zig build -Dtarget=x86_64-linux-musl         # cross-compile
zig build -Dversion=2026.3.1                 # override CalVer string
```

Channel tokens: `all`, `none`, or comma-separated names.
Engine tokens: `base`/`minimal`, `sqlite`, `lucid`, `redis`, `lancedb`, `postgres`, `all`.

---

## 6. Memory Safety Checklist

- [ ] Every `allocator.alloc()` has `defer allocator.free()`
- [ ] Every `ArenaAllocator.init()` has `defer arena.deinit()`
- [ ] Every `ArrayListUnmanaged` uses `.empty` init + explicit allocator
- [ ] ChaCha20Poly1305.decrypt uses stack buffer, not heap
- [ ] `std.fs.File.stdout()` used, NOT `std.io.getStdOut()`
- [ ] `builtin.is_test` guards on all side effects (network, processes, hardware)
- [ ] No vtable returns pointing to stack-allocated structs
- [ ] No `ArrayListUnmanaged.writer()` as `?*Io.Writer`
- [ ] No speculative config/feature flags
