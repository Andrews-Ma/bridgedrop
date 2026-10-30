# Reliability research — 2026-10-29

BridgeDrop remains a small native Swift app for paired file and text transfers. Explicit approval is the default; an optional per-pair automatic acceptance setting was added later. The projects below were reviewed as design references; their source code, services, logos and dependencies are not bundled. BridgeDrop does not speak their wire protocols.

| Reference | Relevant design | BridgeDrop decision |
| --- | --- | --- |
| [LocalSend protocol](https://github.com/localsend/protocol/tree/62bd3406ec80d62f2ed46269cdc06c4dcc391083) | More than one discovery method; metadata preparation before upload; cancellation and optional SHA-256 verification | Retain Bonjour plus authenticated manual-address fallback, approval and final SHA-256; probe the preferred address again after network changes. Do not assume LAN discovery always succeeds. |
| [PairDrop networking](https://github.com/schlagmichdoch/PairDrop/blob/1b0c9c9d903c3cfc706df1303dc75c3b54d04c77/public/scripts/network.js) | Queued files, partition acknowledgements, online/network-change handling, explicit completion messages | Serialize file preparation, cap active senders at two, wait for each saved chunk, and perform bounded recovery. Keep the native foreground app rather than importing a WebRTC/browser stack. |
| [Syncthing BEP](https://docs.syncthing.net/specs/bep-v1.html) and [implementation](https://github.com/syncthing/syncthing/tree/ed38528d7fba3dd6a42c9c9fc6780af432dc15d2) | Explicit block offsets and sizes, hashes, request/response identity | Retain bounded 256 KiB chunks, existing authenticated request IDs and whole-file SHA-256. Check exact ACK offsets and total length before reporting delivery. |

## Implementation

`TransferSender` owns a single transfer state machine. A transient transport failure re-offers the same manifest and transfer ID and obtains the receiver's persisted offset. It retries at most four times with exponentially increasing jittered delays. Each packet exchange also retains the existing three-attempt limit and reuses the same encrypted packet across those attempts. Rejection, cancellation, invalid frames, invalid ACKs, credential errors and TLS validation errors do not trigger automatic sender recovery. Approval has one monotonic ten-minute deadline across retries.

The app keeps at most two send tasks active; cancelled tasks stay registered until cleanup finishes. Waiting jobs can be cancelled before they are offered. Source-file preparation is serialized. A network path monitor refreshes the invitation address and authenticated discovery; a configured preferred address is probed again when needed. Active foreground transfers temporarily prevent idle sleep, and release this hold on pause/completion. macOS opens the existing process when another copy of the same bundle is launched.

AES-GCM and the TCP/relay wire format remain unchanged. Automatic acceptance of new authenticated requests is optional and off by default. Opening a pairing link still requires explicit confirmation before trust is saved or a new connection starts. Text is sent as UTF-8 without trimming or normalization, and never automatically overwrites the receiving clipboard.

## Scope

These mechanisms reduce common interruption and duplicate-send failures; they do not bypass Wi-Fi client isolation, iOS suspension, a missing relay, insufficient storage or a closed receiver. LocalSend is not cited as providing BridgeDrop-style crash recovery. This release does not add protocol interoperability, continuous clipboard monitoring, public relay infrastructure or background iPhone delivery.

## Additional evaluation — 2026-10-30

- [croc](https://github.com/schollz/croc) and [Magic Wormhole](https://github.com/magic-wormhole/magic-wormhole) offer useful pairing and relay designs. Their Go/Python implementations and protocol changes are not bundled; short-code security requires a complete reviewed protocol.
- [KDE Connect iOS](https://github.com/KDE/kdeconnect-ios) and [Nextcloud iOS](https://github.com/nextcloud/ios) inform native lifecycle and file handling research. iOS background transfers would require a separately designed system-managed HTTP workflow and cannot be inferred from the current TCP listener.
- [SwiftNIO](https://github.com/apple/swift-nio) is a mature network framework, but no dependency is added without measurements showing a benefit over Network.framework.
- Version 1.3.0 invalidates expired peer selections and transiently failed cached LAN endpoints, and adds connection guidance. Persistent connections, pipelined acknowledgements and per-device identity require measurement, version negotiation and further security review.
- LocalSend is Apache-2.0, croc and Magic Wormhole MIT, Syncthing MPL-2.0, and PairDrop GPL-3.0. These references are not copied into the application; any future code reuse must review the exact files and dependencies.
