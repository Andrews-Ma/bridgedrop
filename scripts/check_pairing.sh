#!/bin/zsh
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_binary="$(mktemp -t bridgedrop-pairing-check)"
trap 'rm -f "$task_binary"' EXIT
cd "$task_root"
swiftc -swift-version 5 -parse-as-library Sources/BridgeDropCore/*.swift \
    App/TransferActivity.swift App/PairingVault.swift App/PairingInviteCodec.swift App/PairingQRCode.swift App/AppModel.swift \
    scripts/check_pairing.swift -o "$task_binary"
"$task_binary"
