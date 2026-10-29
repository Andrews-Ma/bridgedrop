# 1.1.0 validation — 2026-10-29

## Completed locally

| Check | Result |
| --- | --- |
| Core and sender XCTest | 31 passed, 0 failures |
| Pairing regression | 51 passed; app-link/legacy JSON, malformed and expired input, no trust/write/connect before confirmation, actual QR round-trip |
| Actual AppModel queue | Two active workers; queued cancellation never offered; four exact completed states; no pairing writes; pause/explicit resume and duplicate retry checks passed |
| Relay server | 18 tests passed |
| Encrypted local TCP | Unicode text, 716837-byte file, zero-byte file, approval, replay, saved bytes and restart passed |
| Sender recovery over TCP and local HTTP relay | 3 MiB + 17 bytes; deliberately lost saved-chunk and completion ACKs, recreated receiver store, resumed and compared one exact saved file |
| iOS simulator build | Full iOS SDK compilation passed |
| iOS device-architecture build | Unsigned Release compilation passed; not an installable/signed IPA |
| iOS simulator dispatch | Dedicated iOS 26.3 simulator installed and launched the app and accepted a synthetic cold-start application URL; no live invitation was used |
| macOS package | Apple-silicon Release compilation and strict signature verification passed; application icon bundled |
| Local installation | Version 1.1.0 replaced the existing Mac bundle after a verified full backup; installer did not modify app data, preferences or Keychain |

## Not completed

The computer-use service did not permit access to Simulator or BridgeDrop during this run. Therefore the simulator confirmation page, new macOS GUI startup, displayed icon and repeated-launch behavior have not been visually verified for 1.1.0. The model checks are not substitutes for that UI acceptance.

The listed physical iPhone was unavailable. iOS 26.2 system-camera recognition, cold/warm confirmation-page appearance, actual Mac ↔ iPhone file/text transfers, large-file performance, Wi-Fi changes, locked-screen behavior and physical-device signing/install are still pending. Simulator URL dispatch does not establish system-camera recognition.

No public HTTPS relay was deployed. Local relay tests do not establish Internet reachability or production-service reliability. The existing shared-key and explicit-approval model is retained; no independent cryptographic invitation signature or Universal Links domain is added.

## Reproduce

Use the commands in [BUILDING.md](BUILDING.md). Synthetic fault fixtures and isolated test directories keep live pairing credentials out of tests and logs. GitHub CI repeats the automated checks; its own result must be checked independently of this local validation.
