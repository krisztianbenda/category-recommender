# Tasks: Mail App Integration

**Input**: [spec.md](spec.md), [plan.md](plan.md)

**Tests**: Requested by the constitution's quality gates. Synthetic data only.

## Phase 1: Setup

- [x] T001 Create the Swift package in `mail-app/Package.swift` with `MailCore`, the `CategoryRecommender` app and tests; add `.build/` to `.gitignore`
- [x] T002 Add `mail-app/scripts/test.sh`, which runs Swift Testing under the Command Line Tools

## Phase 2: Foundational

- [x] T003 [P] API types and loopback-only client, refusing other hosts, redirects and proxies, in `mail-app/Sources/MailCore/ServiceClient.swift`, with tests (quality gate; FR-022)
- [x] T004 [P] Mail bridge script with its fake-Mail tests in `mail-app/Resources/mail-bridge.js` and `mail-app/tests/mail-bridge.test.mjs`
- [x] T005 [P] Label mapping and system-folder filter in `mail-app/Sources/MailCore/Labels.swift`, with tests (FR-005, FR-006)
- [x] T006 Make `scripts/run-local.sh` stop cleanly on SIGTERM

## Phase 3: User Stories 1 and 2, P1 (recommend, file, labels in step)

- [x] T007 [US2] Sync plan and runner in `mail-app/Sources/MailCore/LabelSync.swift`, with tests (FR-004, FR-007)
- [x] T008 [US1] Email text clean-up and limits in `mail-app/Sources/MailCore/EmailText.swift`, with tests
- [x] T009 [US1] Filing rules in `mail-app/Sources/MailCore/Labels.swift`, with tests (FR-013, FR-015)
- [x] T010 [US1] Session state in `mail-app/Sources/MailCore/RecommenderSession.swift`, with fake Mail and backend in tests (FR-008 to FR-014)
- [x] T011 [US1] `osascript` runner in `mail-app/Sources/CategoryRecommender/ScriptedMail.swift` (FR-002, FR-003)
- [x] T012 [US1] Floating window and keyboard handling in `mail-app/Sources/CategoryRecommender/PanelView.swift` and `PanelController.swift` (FR-009, FR-012)
- [x] T013 [US1] Menu bar icon, hot key and Mail Services entry in `mail-app/Sources/CategoryRecommender/AppDelegate.swift` and `HotKey.swift` (FR-001)

## Phase 4: User Story 3, P2 (create and delete)

- [x] T014 [US3] Create and delete in the session, with tests (FR-016 to FR-018)
- [x] T015 [US3] Create row, delete confirmation and forget-removed-labels in the window

## Phase 5: User Story 4, P2 (ready when needed)

- [x] T016 [US4] Backend manager in `mail-app/Sources/CategoryRecommender/Backend.swift`, with idle stop (FR-019, FR-020)
- [x] T017 [US4] Install and uninstall scripts, with start at login, in `mail-app/scripts/` (FR-021)

## Phase 6: Verification and polish

- [x] T018 Demo mode with a synthetic mail source, and window snapshots
- [x] T019 End-to-end script against the real service with a stub model and synthetic data, including a socket check (SC-006)
- [x] T020 Real-model run on synthetic email: 300-label prompt fits, and latency (SC-004)
- [x] T021 `--diagnose`, `--self-test-local` and `--self-test-gmail`
- [x] T022 Run the checks that use real Mail, with the owner's approval
- [x] T023 Docs: `mail-app/README.md`, `docs/operations.md`, root `README.md`

## Phase 7: Moved and renamed labels (FR-025)

- [x] T024 [US2] Pair gone and new labels by name in `mail-app/Sources/MailCore/LabelSync.swift` (`MovePlan`), and move or rename the category in place, with tests
- [x] T025 [US2] `holding` in the bridge and `ScriptedMail`, and pairing a renamed label by its learned emails, with bridge tests and a `--self-test-local` step
- [x] T026 [US2] End-to-end: move, rename and parent rename against the real service, in `LiveServiceTests`
- [x] T027 Docs: `mail-app/README.md`, `docs/architecture.md`, this spec and plan
