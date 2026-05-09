---
description: Unified Unreal Engine skill router. Use for UE/Unreal work and route to the narrow active UE skills: debug, impact, execution trace, dev cycle, audit, scaffold, build, migration, networking, rendering, validation, profiling, and safe modify. Prefer this entry point when a request could match multiple UE skills.
---

# UE Unified Router

Use this skill as the first UE decision point. Keep the active skill surface small and route by intent.

## Main Routes

- Build, cook, package, commandlet: use `ue-build-automate`.
- Implement a feature end to end with build/test loop: use `ue-dev-cycle`.
- Generate or scaffold new UE classes/features without full build loop: use `ue-scaffold`.
- Compilation errors, crashes, bugs, Live Coding failures: use `ue-debug`; for Hot Reload/Live Coding specifically, use `ue-livecoding-fix`.
- Change impact, references, callers, Blueprint references, refactor risk: use `ue-impact`.
- Blueprint/GAS/input/widget execution chains: use `ue-execution-trace`.
- Explain a UE system/entity: use `ue-explain`.
- Project health, logs, assets, validation, performance overview: use `ue-audit` first, then `ue-validate`, `ue-insights-profiler`, or `ue-project-ops` as needed.
- C++ refactors with redirects/signature changes: use `ue-cpp-refactor`.
- Version/API migration: use `ue-migrate`.
- Network replication/RPC audit: use `ue-network-audit`.
- CVar/config exploration: use `ue-cvar-explorer`.
- Material generated HLSL extraction: use `ue-hlsl-extract`.
- IK Rig, Sequencer, DL integration, engine metadata, CL history: use their specific active skill when named by the user.
- Risky asset/config/code modification: run `ue-safe-modify` before editing.

## Consolidated Legacy Skills

The following formerly separate skills were intentionally archived because their responsibilities are now covered by the routes above:

- `unreal-error-doctor` -> `ue-debug`
- `caller-graph-visualizer` -> `ue-impact`
- `execution-flow-explorer` -> `ue-execution-trace` / `ue-impact`
- `api-diff-analyzer` -> `ue-migrate`
- `module-analyzer`, `module-mapper` -> `ue-build-automate` / `ue-debug`
- `performance-health-check` -> `ue-audit` / `ue-insights-profiler`
- `asset-modification-wizard` -> `ue-safe-modify` / `ue-validate`
- `blueprint-flow` -> `ue-execution-trace`
- `game-design-intelligence` -> `ue-explain` / `ue-audit`
- `ue-architecture-lint`, `ue-network-lint`, `ue-perf-lint` -> `ue-audit` plus focused audit skills
- `ue-test-iterate` -> `ue-test-gen` plus normal test iteration

## Rule

If a user names a specific active UE skill, use that skill. If the request is ambiguous, start here and choose the smallest matching active skill.
