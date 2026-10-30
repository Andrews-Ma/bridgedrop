# Build and test

Prebuilt macOS downloads do not require development tools. Building requires a Mac with full Xcode and the selected Apple SDKs; Python 3 generates the project and icon containers. BridgeDrop has no third-party Swift dependencies. The optional relay uses the Python standard library.

```sh
swift test
python3 scripts/check_localization.py
swiftc -parse-as-library scripts/check_icon.swift -o /tmp/bridgedrop-icon-check
/tmp/bridgedrop-icon-check assets/mac-icon.png assets/Assets.xcassets/AppIcon.appiconset/ios-1024.png
zsh scripts/check_pairing.sh
zsh scripts/check_model_transfers.sh
swift run bridgedrop-check local
python3 -m unittest discover -s relay/tests -v
python3 scripts/check_relay_integration.py
zsh scripts/build_mac.sh
```

The macOS build produces `outputs/BridgeDrop-Mac-v1.2.0/轻传.app` for Apple silicon, with a local development signature. It does not install over existing apps. `BRIDGEDROP_OUTPUT_APP` selects an alternative output path; `BRIDGEDROP_SIGNING_IDENTITY` selects an existing signing identity. `BRIDGEDROP_RELEASE_DIR` chooses the package output directory.

Open `BridgeDrop.xcodeproj` for the native targets. Build the iOS simulator without signing:

```sh
xcodebuild -project BridgeDrop.xcodeproj -scheme BridgeDrop-iOS \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

For a physical iPhone, select `BridgeDrop-iOS`, an appropriate signing team and your device in Xcode. Do not commit your signing configuration, provisioning profiles or certificates. A successful unsigned device-architecture build is not an installable IPA or device acceptance.

Run `python3 scripts/generate_project.py` after changing the Swift file list. Icon assets are already included; `python3 scripts/generate_icons.py` regenerates Apple containers using macOS `sips` and `iconutil`.

## Testing boundaries

The core tests exercise real temporary files, corruption, recovery and encryption. Sender fault tests deliberately drop acknowledgements after the receiver has saved bytes or completed the transfer, and recreate its store. The model check runs the actual UI model with injected isolated storage and a gated peer to check worker limits and cancellation; it never accesses live pairing credentials. The TCP and local relay checks compare saved bytes, including sender recovery.

These checks do not establish physical iPhone operation, camera recognition, background execution or public-Internet service reliability. Verify those on the intended devices and network before relying on them.
