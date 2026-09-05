# Generic record exploration

User brief: table row → full-value inspector → related records → back to the original context → actual-record graph → same inspector, on SQLite and read-only PostgreSQL.

Base: `29630b191062a6d0d5dfacfd55b26140591c7bb7`; isolated branch `codex/record-inspection-graph`. Integrate committed parity and query-fix checkpoints before final validation. No push or main merge.

## Boundaries

RecordAccess owns validated record locators, catalog foreign-key grouping, bound SELECT plans and bounded pages. RecordWorkspace owns modal exploration history and request generations; its modal retains the originating table/query view, filters, scroll and selection. Opening/switching/closing a database invalidates all record requests immediately. Loaded query rows have no invented provenance: only a separately proven origin may grant navigation.

RecordGraph owns actual record nodes, verified relationship edges, branch contributions and independent layout/camera state. It reuses GraphLayoutModel and viewport geometry. Every expansion is explicit and bounded; page/cap/error state is visible. Root replacement clears exploration budgets. Collapsing a branch prunes unreachable contributions while preserving shared nodes, cycles and distinct relationships.

The inspector uses native selectable text storage for full values, with bounded previews and explicit full-value loading. JSON formatting runs off the main actor; exact copying always uses raw values. NULL and empty text have distinct labels. Metadata descriptions come from the existing sidecar.

A small catalog-validated JSON mapping describes explicit node/edge tables, key/label/source/target/type/direction columns and optional bound equality scopes. It uses the existing sidecar, without domain-specific names or a new project system.

## Validation

Focused SQLite and owned disposable PostgreSQL fixtures cover composite keys, repeated IDs across schemas/tables, nullable and missing foreign keys, multiple foreign keys, cycles, identityless/query snapshots, stale responses and graph caps. Verify PostgreSQL mutation rejection and existing SQLite edit behavior. Build and inspect this worktree's application; disclose unavailable UI/environment checks separately from automated results.
