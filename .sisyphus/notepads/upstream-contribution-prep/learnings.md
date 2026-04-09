## Subsystem Dependency Map (2026-04-08)

### Module Initialization Order (from `src/root.zig`)

**Phase 1: Core** — bus, config, config_paths, util, platform, codex_support, version, state, status, onboard, doctor, capabilities, config_mutator, service, daemon, control_plane, channel_loop, channel_manager, channel_catalog, migration, sse_client, update, export_manifest, list_models, provider_probe, channel_probe, from_json, inbound_debounce

**Phase 2: Agent core** — agent, session, providers, memory, bootstrap

**Phase 3: Networking** — gateway, channels, a2a

**Phase 4: Extensions** — security, cron, health, skills, tools, identity, cost, observability, heartbeat, runtime

**Phase 4b: MCP** — mcp, subagent, subagent_runner

**Phase 4c: Auth** — auth

**Phase 4d: Multimodal** — multimodal

**Phase 4e: Agent Routing** — agent_routing

**Phase 5: Hardware & Integrations** — hardware, integrations, peripherals, rag, skillforge, verbose, tunnel, voice

### Dependency Graph (cross-subsystem imports only)

#### `providers/` imports FROM:
- `../config_types.zig` — ProviderEntry, ApiMode, config structs (heavy usage)
- `../json_util.zig` — JSON parsing helpers
- `../http_util.zig` — HTTP client utilities
- `../platform.zig` — Platform detection
- `../fs_compat.zig` — Filesystem compatibility layer
- `../model_refs.zig` — Model reference data
- `../auth.zig` — OAuth authentication
- `../codex_support.zig` — Codex CLI support
- `../onboard.zig` — Onboarding (api_key.zig only)
- `../provider_names.zig` — Provider name constants
- **NO** imports from channels, tools, memory, security subdirs

#### `channels/` imports FROM:
- `../config_types.zig` — Channel config structs (heavy usage, every implementation)
- `../bus.zig` — Message bus (most implementations: discord, slack, web, dingtalk, lark, qq, teams, maixcam, onebot, mattermost, irc, nostr, signal, imessage)
- `../websocket.zig` — WebSocket client (discord, slack, web, mattermost, onebot, dingtalk, lark, qq)
- `../thread_stacks.zig` — Thread/session tracking (heavy: telegram, discord, slack, signal, etc.)
- `../outbound.zig` — Outbound message dispatch (root, dispatch, lark, dingtalk)
- `../streaming.zig` — Streaming support (root, max, telegram)
- `../platform.zig` — Platform detection
- `../http_util.zig` — HTTP utilities (lark)
- `../fs_compat.zig` — Filesystem compat (signal, dingtalk, imessage, qq)
- `../sse_client.zig` — SSE client (signal)
- `../auth.zig` — Auth (web channel)
- `../security/pairing.zig` — Pairing (web channel)
- `../security/secrets.zig` — Secrets (nostr channel for key decryption)
- `../security/tencent_crypto.zig` — Tencent crypto (wechat, wecom channels)
- `../control_plane.zig` — Control plane (telegram)
- `../voice.zig` — Voice processing (telegram)
- `../interactions/choices.zig` — Interactive choices (max, slack, telegram)
- `../portable_atomic.zig` — Atomic operations (discord, slack, max, qq, onebot, mattermost, telegram)
- `../url_percent.zig` — URL encoding (matrix, mattermost, max_api)
- `../memory/engines/sqlite.zig` — SQLite (imessage only, conditional on `build_options.enable_sqlite`)

#### `tools/` imports FROM:
- `../memory/root.zig` — Memory backend (memory_store, memory_recall, memory_forget, memory_list, file_read, file_write, file_edit, file_append, file_delete, root)
- `../security/policy.zig` — Security policy (shell tool heavily, root)
- `../security/sandbox.zig` — Sandbox (shell, root)
- `../config.zig` — Config (delegate, spawn, root)
- `../config_types.zig` — Config types (root)
- `../bus.zig` — Message bus (message tool)
- `../cron.zig` — Cron scheduler (cron_* tools)
- `../fs_compat.zig` — Filesystem compat (file_* tools, image, pushover)
- `../platform.zig` — Platform detection (shell, pushover, web_search)
- `../http_util.zig` — HTTP utilities (pushover, http_request, web_fetch)
- `../net_security.zig` — Network security (browser, web_fetch, http_request, browser_open)
- `../bootstrap/root.zig` — Bootstrap provider (file_read, file_write, file_edit, file_append, file_delete, root)
- `../subagent.zig` — Subagent manager (spawn tool)
- `../subagent_runner.zig` — Subagent runner (spawn tool)
- `../agent_routing.zig` — Agent routing (schedule tool)
- `../verbose.zig` — Verbose logging (screenshot)
- `../json_util.zig` — JSON utilities (cron_gateway)
- `../json_miniparse.zig` — JSON mini parser (shell)
- `../command_summary.zig` — Command summaries (shell)
- `../path_prefix.zig` — Path security (path_security tool)
- `../util.zig` — JSON escape helper (composio)
- `../providers/root.zig` — Provider factory (delegate tool)
- `../provider_names.zig` — Provider name constants (delegate tool)
- `../mcp.zig` — MCP server (root)

#### `memory/` imports FROM:
- `../config_types.zig` — Memory config (root, registry, retrieval/engine, api engine, rollout, temporal_decay, mmr, qmd)
- `../util.zig` — JSON escape helper (api engine, vector/embeddings)
- `../fs_compat.zig` — Filesystem compat (markdown engine, lifecycle: snapshot/hygiene, retrieval/qmd)
- `../net_security.zig` — Network security (api engine, vector/embeddings, vector/store_qdrant, embeddings_ollama)
- `../providers/api_key.zig` — API key extraction (root)
- `../tools/process_util.zig` — Process utility (retrieval/qmd only)
- Internal cross-imports: `vector/`, `engines/`, `lifecycle/`, `retrieval/` all import from `../root.zig`

#### `security/` imports FROM:
- `../platform.zig` — Platform detection (pairing, firejail, bubblewrap)
- `../fs_compat.zig` — Filesystem compat (secrets)
- Internal: `pairing.zig` imports `secrets.zig`

#### `agent/` imports FROM:
- `../config.zig` — Main config (root, cli)
- `../config_types.zig` — Config types (compaction, prompt, root, cli, context_tokens, max_tokens, commands)
- `../providers/root.zig` — Provider factory (root, compaction, cli, dispatcher, commands)
- `../tools/root.zig` — Tool factory (root, prompt, cli, commands)
- `../memory/root.zig` — Memory backend (root, prompt, cli, memory_loader, commands)
- `../security/policy.zig` — Security policy (root, cli, commands)
- `../bootstrap/root.zig` — Bootstrap provider (compaction, prompt)
- `../observability.zig` — Observability (compaction, prompt, cli)
- `../platform.zig` — Platform detection (root)
- `../multimodal.zig` — Multimodal support (root, memory_loader)
- `../capabilities.zig` — Capabilities (root, commands)
- `../skills.zig` — Skill loading (prompt, commands)
- `../verbose.zig` — Verbose logging (cli)
- `../streaming.zig` — Streaming (cli)
- `../subagent.zig` — Subagent manager (cli, commands)
- `../subagent_runner.zig` — Subagent runner (cli)
- `../bus.zig` — Message bus (cli)
- `../channels/cli.zig` — CLI channel (cli)
- `../inbound_debounce.zig` — Debounce (cli)
- `../codex_support.zig` — Codex support (cli)
- `../onboard.zig` — Onboarding (cli)
- `../agent_routing.zig` — Agent routing (cli)
- `../http_util.zig` — HTTP utilities (cli)
- `../path_prefix.zig` — Path prefix (compaction, prompt)
- `../config_paths.zig` — Config paths (prompt)
- `../identity.zig` — Identity format (prompt)
- `../model_refs.zig` — Model references (context_tokens, max_tokens, commands)
- `../provider_names.zig` — Provider names (context_tokens, max_tokens, commands)
- `../version.zig` — Version info (commands)
- `../command_summary.zig` — Command summaries (commands)
- `../config_mutator.zig` — Config mutation (commands)
- `../control_plane.zig` — Control plane (commands)
- `../tools/spawn.zig` — Spawn tool (commands)

### Cross-Subsystem Coupling Violations

**ZERO direct cross-subsystem violations found.** No provider→channel, channel→tool, tool→provider, or memory→provider imports detected. The architecture is clean.

**Minor coupling concerns (within policy):**
1. `channels/imessage.zig` → `../memory/engines/sqlite.zig` — conditional on `build_options.enable_sqlite`, acceptable for iMessage-specific persistence
2. `channels/wechat.zig` and `channels/wecom.zig` → `../security/tencent_crypto.zig` — acceptable, Tencent-specific crypto is part of the channel's domain concern
3. `tools/delegate.zig` → `../providers/root.zig` — acceptable, the delegate tool needs to create providers dynamically
4. `memory/retrieval/qmd.zig` → `../../tools/process_util.zig` — acceptable, QMD engine spawns external processes
5. `channels/web.zig` → `../security/pairing.zig` + `../security/secrets.zig` — acceptable, the web channel implements pairing directly
6. `channels/nostr.zig` → `../security/secrets.zig` — acceptable, Nostr needs key decryption

### DDD Bounded Context Classification

**Core/Infrastructure (foundation, imported by everyone):**
- `config.zig` / `config_types.zig` — configuration schema
- `platform.zig` — platform detection
- `fs_compat.zig` — filesystem compatibility
- `http_util.zig` — HTTP utilities
- `json_util.zig` — JSON utilities
- `bus.zig` — message bus
- `util.zig` — general utilities

**Domain (business logic):**
- `agent/` — agent loop, prompt building, compaction, commands
- `providers/` — AI model provider integrations
- `memory/` — memory storage, retrieval, embeddings, vector search
- `security/` — policy, secrets, sandboxing, pairing
- `tools/` — tool execution surface

**Adapters (external system integration):**
- `channels/` — messaging platform adapters (Telegram, Discord, Slack, etc.)
- `peripherals.zig` — hardware peripheral adapters
- `runtime.zig` — runtime adapters (native, docker, WASM)
- `tunnel.zig` — tunnel adapters (cloudflare, ngrok, tailscale)

**Application/Orchestration:**
- `gateway.zig` — HTTP gateway, webhook routing
- `daemon.zig` — daemon supervisor
- `channel_loop.zig` — channel event loop
- `channel_manager.zig` — channel registration/management
- `session.zig` — session lifecycle
- `subagent.zig` / `subagent_runner.zig` — subagent orchestration
- `onboard.zig` — setup wizard
- `migration.zig` — data migration

### Key Architectural Observations

1. **`config_types.zig` is the universal dependency** — every subsystem imports it. This is the shared types/kernel.

2. **`agent/` is the heaviest consumer** — imports from nearly every subsystem. This is expected: the agent loop orchestrates everything.

3. **Providers are isolated** — they only import config types, HTTP util, and platform detection. No coupling to channels, tools, or memory.

4. **Security is a leaf module** — only `platform.zig` and `fs_compat.zig` dependencies. Everyone imports security; security imports nothing from other subsystems.

5. **Memory is mostly self-contained** — imports config types, fs_compat, http/net utilities. Only one cross-boundary: `providers/api_key.zig` for embedding provider auth.

6. **Channels depend on `bus.zig` and `thread_stacks.zig`** — the bus is the primary inbound message path; thread_stacks manages session isolation.

7. **Tools bridge memory + security** — file tools need bootstrap/memory for file change tracking; shell needs security/policy for sandboxing.
