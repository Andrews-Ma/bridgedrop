# BridgeDrop · 轻传

<img src="assets/app-icon.png" alt="BridgeDrop icon" width="96">

English | [简体中文](README.zh-CN.md)

A native Mac and iPhone app for sending files and pasted text between your own devices. It uses application pairing instead of AirDrop, iCloud or a shared Apple account. The interface defaults to English; choose Simplified Chinese in Settings → Language.

## Download

- **Mac:** [Apple silicon download](../../releases/tag/v1.3.0), macOS 13 or later. Unzip and move `轻传.app` to Applications. The download may trigger macOS security checks; follow the system guidance and [Apple's instructions](https://support.apple.com/102445).
- **iPhone:** build `BridgeDrop-iOS` from `BridgeDrop.xcodeproj` with your own signing team. There is currently no App Store, TestFlight or installable IPA distribution. See [installation](docs/INSTALL.md) and [building](docs/BUILDING.md).

## Use

1. Open BridgeDrop on both devices. On the Mac open **Pair**.
2. Scan the invitation in BridgeDrop, or use the iPhone camera if it offers an app-link entry. If it does not, use **Pair → Import invitation → Scan another device** or paste the invitation inside BridgeDrop. Check the device information and explicitly confirm before pairing is saved.
3. Select the authenticated device. Choose files, or paste text and send. The receiver approves each transfer, or can enable auto-accept for new requests from the current paired group. Received text is copied only when you choose to copy it.
4. Keep both apps open. Transient network failures get bounded automatic recovery from the saved offset. After a longer interruption use **Resume**. A rejected or cancelled transfer needs a new receive request.

New QR codes contain an application link; legacy raw JSON invitations still work inside the app. Invitations contain pairing credentials: share them only with your own device and handle them in BridgeDrop, never a search box or QR decoding website. Simply opening a link only stages the confirmation page. On iPhone, explicitly enable the existing connection after returning from the background.

### History and auto-accept

Auto-accept is off by default and applies to new requests from the current paired group; each device controls its own setting. Existing pending requests still require approval. Delivered text clears the input only when it has not been edited since submission. Finished history entries can be removed individually or in bulk; received files and recovery receipts are retained.

## Reliability

- 256 KiB chunks with persisted receiver offsets, identical-replay checks and final SHA-256 verification.
- Saved-file completion is acknowledged only after verification, rename and ledger persistence.
- Four bounded sender recovery attempts for transient errors; explicit rejection, bad ACKs and credential/TLS errors stop recovery.
- At most two active senders, serialized file staging, cancellable queued work and no duplicate sender for a rapid retry.
- Bonjour discovery, authenticated manual-IP fallback and network-change reprobes. One macOS instance per bundle identifier.
- Active foreground transfers prevent idle sleep. iPhone backgrounding still pauses networking.
- Text keeps its original UTF-8 bytes, including line breaks, whitespace and emoji. No clipboard monitoring or automatic clipboard replacement.

Files are limited to 10 GiB, text to 1 MiB, and each selection to 20 files. These protocol limits are not claims of full-size device performance testing. Compress folders before sending.

## Network and privacy

The same reachable LAN is preferred; no Internet service is required for LAN transfers. Manual IP cannot bypass guest-network isolation. Port 47185 is an encrypted TCP application port, not a web page. Across different networks, configure your own [HTTPS relay](relay/README.md); there is no bundled public relay.

CryptoKit AES-GCM protects the contents, with pairing secrets stored in Keychain. This is a shared-key pairing group, without forward secrecy or per-device key revocation. The relay receives ciphertext and routing metadata. Received files, text, outgoing staging and history are stored locally and are not separately encrypted by the application. Back up important files independently. See [architecture](docs/ARCHITECTURE.md).

## Verification

Local Mac and iPhone testing covered bidirectional text, a 5 KB file and a 2 MiB file, automatic acceptance and manual approval. Automated checks cover core storage, sender recovery, pairing, history, draft editing and local encrypted TCP/relay behavior. iOS simulator and device builds compile. See the validation record for the tested version and scope.

iOS 26.2 system-camera recognition, public HTTPS relay, very large files and broader real-network/background reliability remain unverified. See [validation](docs/VALIDATION.md). Design references and adoption decisions are in [research](docs/RESEARCH.md).

## Develop and license

Build, test and SDK instructions are in [BUILDING.md](docs/BUILDING.md). Swift has no third-party package dependencies; the optional relay uses Python's standard library. Source code and binary downloads are separate deliverables.

[MIT License](LICENSE). The original application icon was generated with an image-generation tool; published PNGs have auxiliary metadata removed. The referenced open-source projects are design research, not bundled implementations. Review [PUBLISHING.md](PUBLISHING.md) before sharing changes.
