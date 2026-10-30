# 1.2.0 validation — 2026-10-30

| Check | Result |
| --- | --- |
| Core and sender XCTest | 31 passed, 0 failures |
| Pairing regression | 51 passed, including new and legacy invitations, invalid input and no trust/write/connection before confirmation |
| Translation | 16 behavior checks, explicit UI/scanner coverage, preserved user-supplied names and text, and isolated preference check passed |
| Model queue and retry | Two active workers, queued cancellation, pause/resume and duplicate retry checks passed |
| Mac application | Release build and signature verified; installed after full backup. English default, immediate Simplified Chinese and English switch, and Chinese preference after restart were verified in the real Mac UI. One installed process listened on port 47185. |
| App icon | Rounded Mac PNG and extracted ICNS have transparent corners; iOS icon uses an opaque square source for the system mask. The rounded artwork was visually inspected. |
| iOS | Simulator and unsigned device-architecture builds succeeded. No iPhone signing or physical-device install was performed. |
| Privacy | The curated current source and package were checked for known personal names, local account paths, email addresses, credentials and image metadata. This is a targeted scan, not proof that every possible sensitive item is absent. |

The existing public repository owner and historical Git commits retain their previous account and author metadata. The current source uses a neutral copyright attribution and generic default device names; an existing user-selected device name remains on the user's device. Local data, pairing credentials and received files were not changed by the installer.

The 1.1.0 local TCP and relay recovery checks passed before this update; transfer protocol and encrypted transport code have not been changed. iOS 26.2 system-camera recognition, actual Mac ↔ iPhone file/text transfers, public HTTPS relay and background behavior remain unverified. Compiling an iOS app is not equivalent to installing or testing it on a physical iPhone.

Use the commands in [BUILDING.md](BUILDING.md) to reproduce the automated checks. GitHub CI must be checked separately from local testing.
