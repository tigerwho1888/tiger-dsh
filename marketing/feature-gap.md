# Feature gap: old "dsh-remote" web app vs new TigerDSH iOS app

Date: 2026-10-06

Compared:

- **Old app**: the retired single-file mobile web app, `~/.dsh/archive/2026-10-03-dsh-remote-removal/vault-.agents-dsh-remote/lib/page.html` (2,686 lines — its full feature list was read out of the code).
- **New app**: TigerDSH, native SwiftUI, `~/Developer/tiger-dsh/`. Evidence: `FEATURE-TESTS-A.md` (14 chat features, 12 pass / 1 fail / 1 blocked), `FEATURE-TESTS-B.md` (24 panel/settings features, 18 pass / 6 blocked), `README.md`, and the source under `TigerDSH/Views/`, `TigerDSH/Core/`, `TigerDSH/App/`.

## 1. Verdict

**Yes — the new app covers the old app's feature set almost feature-for-feature.** Of everything the old web app did, only **1** small thing is genuinely missing (the purpose-built digest-watch status card). The real risk is elsewhere: 9 features are built but never test-verified, and 1 shipped feature (the jump-to-bottom arrow) is confirmed broken.

## 2. Feature table

Legend: **covered** = built and (where a test exists) verified. **blocked-unverified** = built, but the test sweep could not exercise it. **failing** = built and confirmed defective. **missing** = the old app had it, the new one does not.

### Chat list (home)

| Feature | Old web app | New iOS app | Notes |
|---|---|---|---|
| Chat list grouped by project | yes | covered | Tested pass (A). Collapse/expand groups and "Show N more" (12-row cap) both present in `HomeView.swift`. |
| Filters: All / Working / Answer / Archived | yes | covered | Tested pass (A). |
| Search chat titles | yes | covered | Tested pass (A). |
| Search inside chats (full text) | yes | covered | `session/search` in `HomeView.swift`. |
| Summary line (N chats · projects · working · needs you) | yes | covered | `HomeView.swift` summary. |
| Long-press row menu: Rename / Pin / Fork / Archive | yes | covered | Native context menu; Rename tested pass (B). |
| New chat: project, agent preset, model, effort, first message, free-text folder | yes | covered | `NewChatSheet.swift` has all of these, but no test in either sweep ever created a chat. |
| Offline banner + cached chats for offline reading | yes | covered | "Offline · showing data from …" + disk cache (`AppModel.swift`). |
| Pull-to-refresh | no | covered | **New-only**; the web app had a menu item plus 30 s auto-refresh instead. |

### Chat screen

| Feature | Old web app | New iOS app | Notes |
|---|---|---|---|
| Open chat, markdown replies (tables, code, quotes, lists) | yes | covered | Tested pass (A). |
| Streaming reply | yes | covered | Tested pass (A). |
| Load earlier messages | yes | covered | `session/page` in `ChatModel.swift`. |
| Run bar with timer, model name, Stop button | yes | covered | Tested pass (A). |
| Jump-to-bottom arrow | yes | **failing** | Tested fail (A): the arrow never disappears after tapping and shows even at the bottom. |
| Composer: typing, drafts kept per chat | yes | covered | Typing/sending tested pass (A). |
| Attachments: photos, files, camera, HEIC→JPEG | yes | covered | Tested pass (A); native camera picker added. |
| Voice dictation (mic button → Mac speech-to-text, setup flow) | yes | **blocked-unverified** | Setup screen tested pass (B); the actual record→transcribe path (`MicRecorder` in `Composer.swift`) was never exercised end-to-end. |
| Slash commands + skills autocomplete | yes | covered | Commands/skills sheet tested pass (B); autocomplete popover in `Composer.swift`. |
| @ file and chat references | yes | covered | `fileReferences/list` + `sessionReferenceResolver/candidates` in `Composer.swift`. |
| Queued messages: view, edit, send now, remove | yes | covered | Tested pass (A). |
| Questions dock (options, custom answer, multi-select) | yes | covered | Tested pass (A). |
| Approvals (Allow once / Reject, "N more waiting") | yes | **blocked-unverified** | Built (`AppModel.swift`, `ChatSheets.swift`); the host never asked in two probes (A). The phone's safety gate is unproven. |
| Retry row + "Try again" after a failed model call | yes | **blocked-unverified** | Built; no failing model call ever occurred during testing (A). |
| Edit a past message → branch; regenerate reply; branch from here | yes | covered | Edit + branch tested pass (A); branch-from-here and fork in code. |
| Copy / quote a reply | yes | covered | `MessageViews.swift`. |
| Feedback thumbs with note | yes | covered | Tested pass (A; sheet cancelled without saving). |
| Folded thinking + grouped tool steps ("Read files", "Ran commands") | yes | covered | `ProcessGroupHeader`, `ToolGroupChip` in `MessageViews.swift`. |
| Long user messages fold with "Show full prompt" | yes | covered | `MessageViews.swift`. |
| Code changes: per-turn summary, changed-files list, diff viewer | yes | changes list covered; diff **blocked-unverified** | Changes list tested pass (B); diff viewer built but its test tapped the wrong row and was never re-run. |
| Workflow run cards (phases, member outcomes, tap into member) | yes | **blocked-unverified** | Built (`WorkflowCard`); no workflow ran during testing (B). |
| "Files from this chat" (deliverables) | yes | **blocked-unverified** | Built; the test chat had produced no files (B). |
| Subagent chats: open, read-only or messageable | yes | covered | Subagents sheet tested pass (B); `subagents/prompt` in code. |
| Agent team: members + shared task board | yes | covered | Tested pass (B). |
| Background jobs: list, live output, stop | yes | covered | Tested pass (B). |
| Goal: create, pause, resume, complete, clear | yes | covered | Tested pass (B). |
| To-do list chip and sheet | yes | covered | Tested pass (B). |
| Files browser + text/image preview | yes | browser covered; preview **blocked-unverified** | Browser tested pass (B); preview rendered correctly by hand but the assertion was never re-run. |
| Per-chat model and effort picker | yes | covered | Tested pass (B). |
| Per-chat permissions mode | yes | covered | Tested pass (B). |
| "auto-approved · yolo mode" hint | yes | covered | `Composer.swift`. |

### Plugins and scheduler

| Feature | Old web app | New iOS app | Notes |
|---|---|---|---|
| Plugin list with on/off switches, required section | yes | covered | Tested pass (B). |
| Plugin detail page, remove plugin | yes | covered | Detail tested pass (B); remove in code. |
| Get plugins (look up + install by package name) | yes | covered | `PluginsView.swift` inspect/install; not exercised by tests. |
| Usage/quota status with bars, balance, reset countdown | yes | covered | Dedicated `QuotaView` in `PluginsView.swift`. |
| Digest-watch status card (batches, tokens owed, red defect block) | yes (purpose-built) | **missing** | New app shows the same JSON as generic labelled values (`GenericJSONView`); the formatted card and its red "needs a look" warning are gone. |
| Other plugins' status pages (generic) | yes | covered | Same generic-JSON approach in both. |
| Scheduler: list, timing labels, detail, delivery history, delete, open conversation, edit name/instruction | yes | **blocked-unverified** | Built (`SchedulerView.swift`); this Mac has only ended tasks, so editing could not be opened, and neither app can create a task from the phone (the host offers no create call — the assistant creates them). |
| Voice-input plugin page | yes | covered | Tested pass (B). |

### Settings and app shell

| Feature | Old web app | New iOS app | Notes |
|---|---|---|---|
| Models & providers: default model, API keys, base URL, add/remove provider and model, fetch models from endpoint, known-provider list | yes | covered | Tested pass (B). Keys go straight to the Mac, never stored on the phone — same as old. |
| Connection state, sockets opened/closed, list age | yes | covered | `SettingsView.swift`. |
| "Features on this DSH" availability list | yes | covered | `SettingsView.swift`. |
| Performance overlay | yes (settings toggle) | covered | Toggle + reset counters in `SettingsView.swift`. |
| Clear cached data | yes | covered | `SettingsView.swift`. |
| Theme follows the phone | yes | covered | Native. |
| Sign out | no | covered | **New-only**, but **blocked-unverified** — its test run was killed before it started (B). |
| Auto-reload when a newer build is installed | yes | n/a | Web-app concern; a native app updates through Xcode/App Store instead. |
| Keyboard avoidance, edge-swipe back, drag-to-dismiss sheets | yes (hand-built) | covered | Native in SwiftUI. |
| Haptics | no | no | Neither app has them — the old web app never called the vibration API. |

## 3. Missing in the new app (ranked by how much a daily phone user would miss it)

1. **Digest-watch status card.** The old app rendered the digest run as a proper card — batches finished, tokens owed, quiet time, and a red "needs a look" warning when something was wrong. The new app shows the same data as plain labelled values, so a broken digest run no longer stands out. Small, but it is the only feature the old app had that the new one genuinely lost.

Everything else the old app did exists in the new app. The honest caveats, in order of daily impact:

- **Jump-to-bottom arrow is broken** (confirmed, not missing): it never disappears, so it is useless as a "new messages below" signal.
- **Approvals are unproven**: built, but never once seen working — if they fail, a chat set to "ask" cannot be unblocked from the phone.
- **Voice dictation is unproven end-to-end**: the setup screen works; actually speaking into a chat was never tested.
- **Scheduler editing is unproven** (and creation is impossible on both apps — the host has no create call, so tasks are born by asking the assistant).
- **Diff viewer, file preview, deliverables, workflow cards, retry, sign-out**: all built, none verified.

## 4. What the new app does that the web app never did

- **Sign out** from the phone (the web app could only show "sign-in expired").
- **Pull-to-refresh** on the chat list, settings, scheduler and plugins.
- **Native camera picker** and native photo/file pickers.
- **Year-long sign-in kept in the Keychain** with a paste-the-link connect screen (the web app lived and died with the browser session).
- **Native feel for free**: system search bar, context menus, swipe-back, sheet detents, empty-state screens — the web app hand-built approximations of all of these.
- **Performance overlay with resettable counters** (the old HUD had no reset).
- **A real UI-test suite** that drives the app against a live host (A + B sweeps); the web app had no automated tests at all.

## 5. Recommended next three builds

1. **Fix the jump-to-bottom arrow** — the only confirmed defect: hide it at the bottom and after tapping it.
2. **Prove approvals and retry end-to-end** — run one chat in "ask" mode and one with a deliberately failing model route, so the phone's safety net is verified, not assumed.
3. **Local notifications for "needs your answer" and approvals** — the one high-value thing a native app can do that a web page never could; this is what makes the phone app worth keeping open.
