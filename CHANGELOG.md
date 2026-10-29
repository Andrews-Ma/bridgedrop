# Changes

## 1.1.0 — 2026-10-29

- Add a resumable sender with bounded transient recovery and exact acknowledgement checks.
- Limit active senders to two and serialize file preparation; cancel queued work before it is offered.
- Refresh authenticated discovery and the preferred address after network changes.
- Temporarily prevent idle sleep during foreground transfers; pause safely with iPhone backgrounding.
- Activate an existing macOS instance rather than starting another copy with the same bundle identifier.
- Add an original application icon for macOS and iPhone, installation documentation and reproducible checks.
- Preserve app-link confirmation, legacy JSON import, AES-GCM and the existing receiving ledger/wire protocol.

Physical iPhone camera and cross-device acceptance remain pending. The optional relay has only been tested locally.
