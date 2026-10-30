# Changes

## 1.3.0 — 2026-10-30

- Add optional per-pair automatic acceptance, finished-transfer history removal and bulk cleanup, and clear an unchanged text draft only after verified delivery.
- Clear expired peer selections and stale LAN endpoints, improve connection guidance, and clarify the shared-key trust boundary.
- Update validation to reflect physical iPhone testing and correct copyright attribution.

## 1.2.0 — 2026-10-30

- Default to English, with a persistent Simplified Chinese option in Settings. Localize pairing, transfer status, scanner and error messages while preserving saved transfer state and user-entered text.
- Use a rounded, transparent macOS icon and retain a separate iOS system-masked icon.
- Use generic default device names and remove personal account names and machine paths from current public source and package notes.
- Preserve the transfer protocol, stored pairing credentials and saved files.

## 1.1.0 — 2026-10-29

- Add a resumable sender with bounded transient recovery and exact acknowledgement checks.
- Limit active senders to two and serialize file preparation; cancel queued work before it is offered.
- Refresh authenticated discovery and the preferred address after network changes.
- Temporarily prevent idle sleep during foreground transfers; pause safely with iPhone backgrounding.
- Activate an existing macOS instance rather than starting another copy with the same bundle identifier.
- Add an original application icon for macOS and iPhone, installation documentation and reproducible checks.
- Preserve app-link confirmation, legacy JSON import, AES-GCM and the existing receiving ledger/wire protocol.

Physical iPhone camera and cross-device acceptance remain pending. The optional relay has only been tested locally.
