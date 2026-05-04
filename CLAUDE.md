# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Layout

This repo is a multi-component backend for the open-source `xiaozhi-esp32` voice assistant. Four independent sub-projects live under `main/`:

- `main/xiaozhi-server` — Python real-time server (WebSocket + HTTP). Runs ASR/LLM/TTS/VAD pipelines, MCP, plugins. Python 3.10.
- `main/manager-api` — Spring Boot 3 / Java 21 management API. MySQL + Redis + Liquibase + Shiro auth + MyBatis-Plus.
- `main/manager-web` — Vue 2 admin console (Element UI, Vuex, vue-cli).
- `main/manager-mobile` — Vue 3 + uni-app mobile/H5 console (pnpm, Vite, Pinia, alova, UnoCSS).

Deployment, integration, and protocol docs live in `docs/`. The repo root carries multilingual READMEs and Dockerfiles for the three deployable components (`Dockerfile-server`, `Dockerfile-server-base`, `Dockerfile-web`).

## Common Commands

Python server (`main/xiaozhi-server`):
- `pip install -r requirements.txt` — install deps. FFmpeg and libopus must be installed at the OS level.
- `python app.py` — run the server. Requires `data/.config.yaml` (copy `config_from_api.yaml` for full-module mode, or copy/edit `config.yaml` keys into a local override for standalone mode).
- `python performance_tester.py` — benchmark configured ASR/LLM/VLLM/TTS providers (only those with keys are tested).
- `docker compose -f docker-compose.yml up -d` — single-service container; `docker-compose_all.yml` brings up the full stack.

Java API (`main/manager-api`):
- `mvn spring-boot:run` — run locally (Java 21, MySQL 8, Redis 5+ required).
- `mvn clean package -Dmaven.test.skip=true` — build the jar.
- `mvn test -DskipTests=false` — POM skips tests by default; pass this flag to actually execute JUnit 5 tests under `src/test/java`.
- API docs: `http://localhost:8002/xiaozhi/doc.html` (Knife4j).

Web console (`main/manager-web`):
- `npm install && npm run serve` — dev server.
- `npm run build` — production build. `npm run analyze` for bundle analysis.

Mobile/H5 console (`main/manager-mobile`):
- `pnpm i` — install (pnpm is enforced via `preinstall` `only-allow`).
- `pnpm dev:h5`, `pnpm dev:mp-weixin`, `pnpm dev:app-android`, etc. — platform-specific dev targets.
- `pnpm build:h5`, `pnpm build:mp-weixin`, etc. — production builds per target.
- `pnpm type-check` (vue-tsc) and `pnpm lint` (ESLint) — required before shipping mobile changes; commit hooks via husky/lint-staged enforce ESLint on staged files.

## Architecture Big Picture

### Two deployment modes

The Python server is designed to run either **standalone** (config from local YAML, no DB, single agent) or **full-module** (config fetched from the Java API, multi-tenant via the web console). The switch is driven by whether `manager-api.url` is set in `data/.config.yaml`:

- `config/config_loader.py:load_config` reads `config.yaml` (defaults) and `data/.config.yaml` (override). If `manager-api.url` exists, it calls `get_config_from_api_async` and treats the API as the source of truth (sets `read_config_from_api=True`); otherwise it merges YAML configs locally.
- The same code path serves both modes — provider modules don't know which mode is active. When adding config-driven behavior, ensure the key works in both pure-YAML and API-fetched configs.

### Python server runtime (`main/xiaozhi-server`)

`app.py` boots two concurrent servers:
- `WebSocketServer` (default port 8000, path `/xiaozhi/v1/`) — the device-facing real-time channel.
- `SimpleHttpServer` (default port 8003) — OTA endpoints (`/xiaozhi/ota/`) and the vision MCP endpoint (`/mcp/vision/explain`). When `read_config_from_api=True`, OTA is served by the Java API and only vision is registered here.

A global GC manager (`core/utils/gc_manager.py`) runs every 5 minutes. `auth_key` is resolved with priority: `server.auth_key` → `manager-api.secret` → random UUID, used for JWT (vision API, OTA token, websocket auth).

Per-connection lifecycle is owned by `core/connection.py:ConnectionHandler`. One handler instance per device websocket: it deep-copies the global config, runs its own dialogue state (`core.utils.dialogue.Dialogue`), and holds references to shared, lazily initialized provider singletons (`_vad`, `_asr`, `_llm`, `_intent`, `_memory`) created in `core/utils/modules_initialize.py:initialize_modules`. TTS is per-connection. Don't mutate the singletons from a connection.

### Provider plugin pattern

`core/providers/{asr,llm,tts,vad,vllm,intent,memory,tools}/` each follow the same pattern:
- A `base.py` with the abstract interface.
- Concrete files/folders per backend (e.g. `llm/openai/`, `tts/edge.py`, `asr/aliyun_stream.py`). Streaming variants are usually named `*_stream.py`.
- The active provider is chosen by `selected_module.{ASR,LLM,TTS,...}` in config and instantiated by `core/utils/{asr,llm,tts,...}.py` using the config block named after the selected provider.

To add a new provider, create the module under the right directory, subclass `base.py`, and register a config entry under the matching top-level section in `config.yaml` — the loader will pick it up by name.

### Plugin (function-call) system

`plugins_func/loadplugins.py` auto-imports every module in `plugins_func/functions/` at startup (called from `core/connection.py`). Each plugin uses decorators in `plugins_func/register.py` to register a `FunctionItem` with a `ToolType` (NONE / WAIT / CHANGE_SYS_PROMPT / SYSTEM_CTL / IOT_CTL / MCP_CLIENT) and returns an `ActionResponse(Action, result, response)` where `Action` controls what the runtime does next (RESPONSE / REQLLM / RECORD / NONE). New plugins added under `plugins_func/functions/` are picked up automatically — no registry edit needed.

Tool dispatch is unified through `core/providers/tools/unified_tool_handler.py` (`UnifiedToolHandler`), which composes built-in plugin tools with MCP-server tools, MCP-endpoint tools, and IOT/client-side tools.

### Text/audio message handling

Inbound websocket messages flow through `core/handle/textHandle.py` → `textMessageProcessor` → handlers registered in `textMessageHandlerRegistry` (one per `textMessageType`). Audio chunks go through `receiveAudioHandle` → VAD → ASR → intent → LLM → TTS → `sendAudioHandle`. When touching the protocol, prefer adding a new handler module under `core/handle/textHandler/` and registering it, rather than expanding existing handlers.

### Java manager-api (`main/manager-api`)

Standard Spring Boot layered structure:
- Base package `xiaozhi`. `xiaozhi.common.*` holds cross-cutting infra (aspects, config, exceptions, interceptors, paging, redis, xss, validators). `xiaozhi.modules.*` holds business domains: `agent`, `device`, `model`, `config`, `knowledge`, `llm`, `timbre`, `voiceclone`, `correctword`, `security`, `sms`, `sys`.
- Each module follows `controller` → `service` → `dao` (MyBatis-Plus mapper) with `entity`/`dto`/`vo` separation. MyBatis XML lives in `src/main/resources/mapper/`.
- DB schema migrations are in `src/main/resources/db/` (Liquibase). Changesets must be additive — do not edit applied changesets.
- Shiro + JWT for auth; the shared secret with the Python server is `server.secret` (set at first deploy via the web console's Parameter Management page, then mirrored into `xiaozhi-server/data/.config.yaml` as `manager-api.secret`).

### Frontend consoles

- `manager-web` (Vue 2 + Element UI): standard `src/{router,store,api,views,components}` layout. Communicates with `manager-api`. Use the existing axios + `api/` patterns when adding endpoints.
- `manager-mobile` (Vue 3 + uni-app, multi-target): pages in `src/pages`, layouts in `src/layouts`, components in `src/components`, alova-based API client with openapi codegen (`pnpm openapi-ts-request`). UnoCSS for styling. Enforces 2-space indent, LF, UTF-8, ESLint via `@antfu/eslint-config`.

## Coding Conventions

Match the conventions of the component you are editing — they differ:
- Python: snake_case modules and functions, async handlers, `loguru` via `config.logger.setup_logging()` (use `logger.bind(tag=TAG)` per module).
- Java: package `xiaozhi`, layered `Controller`/`Service`/`Dao`/`DTO`/`VO`/`Entity` suffixes, MyBatis-Plus.
- Vue (web): single-file components, existing route/store/API patterns. The web console is Vue 2 — do not use Vue 3 Composition API there.
- Mobile: Vue 3 + `<script setup lang="ts">`. ESLint must pass; `pnpm lint:fix` for autofixes.

## Configuration & Secrets

- `main/xiaozhi-server/data/.config.yaml` is git-ignored and per-environment — never commit it. `config.yaml` at the repo level holds defaults; `config_from_api.yaml` is the template for full-module mode.
- Generated/build artifacts (`dist/`, `target/`, `node_modules/`, `data/`, `models/*.pt`) must not be committed.
- The Python server requires FFmpeg and libopus on the host. The check runs at startup via `check_ffmpeg_installed`.

## Testing

- Java: JUnit 5 under `main/manager-api/src/test/java` (e.g. `AESUtilsTest.java`). Pass `-DskipTests=false` to run them.
- Python: no formal unit-test framework checked in; validation relies on `performance_tester.py` and the manual harness `test/test_page.html` (open in Chrome). For provider/protocol changes, add focused scripts under `test/` or document manual verification steps.
- Frontend: no automated tests — at minimum the relevant build must succeed; for mobile also `pnpm type-check` and `pnpm lint`.

## Commits & PRs

Recent history mixes merge commits with short Chinese summaries; mobile uses Conventional Commits enforced by commitlint. Prefer concise, scoped messages (`fix: correct prompt cache key`, `docs: update deployment steps`). PR descriptions should call out the affected module, any config/migration steps, and tests run. Include screenshots for UI changes.
