# Scan History Chunking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-file scan history write path with 100-record chunk files, lazy page loading, full-chunk search, and isolated graph storage while leaving legacy files untouched and ignored.

**Architecture:** `HistoryChunkStorage` owns the new `Documents/scan_history` format. `ScanHistoryStore` remains the main-thread observable facade and publishes the currently loaded page(s). `ProductsTabView` triggers older-page loads and performs background searches through the facade. `GraphArchive` switches only its active directory from `graphs` to `graphs-v2`.

**Tech Stack:** Swift 5.0, iOS 16, SwiftUI, Foundation, XcodeGen, standalone `swiftc` Foundation tests.

**Spec:** `docs/superpowers/specs/2026-09-11-scan-history-chunking-design.md`

## Global Constraints

- Never read, migrate, overwrite, or delete `Documents/scan_history.json`.
- Never read or delete the legacy `Application Support/graphs` directory.
- Keep the existing 5,000 history limit and newest-first ordering.
- Keep `ProductsTabView` on `ScrollView` + `LazyVStack` for the iOS 16 update bug workaround.
- Do not add an index, manifest, third-party dependency, or infrastructure change.
- Do not touch the untracked `AGENTS.md` file.

---

## Task 1: Add failing storage tests

- [x] Add a standalone Foundation test fixture that creates `ScanHistoryItem` values and a temporary chunk directory.
- [x] Test adding 250 records creates three chunks and returns newest-first pages without duplicates.
- [x] Test a legacy `scan_history.json` beside an absent chunk directory is ignored.
- [x] Test search finds a matching record in an older chunk.
- [x] Test update and deletion locate records outside the currently loaded page, preserve sparse chunks, and remove empty chunks.
- [x] Test appending beyond 5,000 removes the oldest records.
- [x] Test clear removes the new chunk directory.
- [x] Run the test before implementation and record the expected compile failure.

## Task 2: Implement the chunk storage

- [x] Add `HistoryChunkStorage.swift` with chunk discovery, JSON encoding/decoding, atomic writes, page loading, full search, append, update, remove, clear, and debug batch replacement.
- [x] Keep sequence numbers monotonic and avoid chunk rebalancing.
- [x] Track the current total count in the storage instance after loading so normal appends do not decode every chunk.
- [x] Skip malformed chunks and preserve the last good file if a write fails.
- [x] Run the storage tests and make them pass.

## Task 3: Refactor `ScanHistoryStore`

- [x] Remove all reads and writes of `scan_history.json`.
- [x] Add initial-page, load-more, search, total-count, and loading state while retaining the observable store facade.
- [x] Route add/update/remove/clear and the DEBUG dummy generator through `HistoryChunkStorage`.
- [x] Update `SearchTabView` and `SettingsView` for any asynchronous store operations and total-count reporting.

## Task 4: Update history UI and graph isolation

- [x] Make `ProductsTabView` search across all chunks, show search progress, reset to the newest page when cleared, and trigger `loadMore()` at the last loaded row.
- [x] Keep selection and detail navigation operating on the currently displayed records.
- [x] Change `GraphArchive` to `graphs-v2`, leaving the legacy directory untouched.
- [x] Keep history deletion scoped to the new history and graph locations.
- [x] Regenerate the Xcode project with XcodeGen.

## Task 5: Verify and document

- [x] Run all relevant standalone tests.
- [x] Build the iOS target for an iOS 16 simulator with code signing disabled; do not launch the simulator.
- [x] Run `git diff --check` and inspect the final diff for legacy-file access.
- [x] Update `FREEMIUM-PLAN.md` section 4.2g from planned to implemented, including the no-migration decision and final paths.
- [ ] Commit the implementation and push `main` to `origin`.
