# Validation and limits — 2026-10-30

## Physical devices

The locally installed Mac and iPhone builds preceding 1.3.0 were used for bidirectional text and file tests on the same reachable LAN. Text included Chinese, line breaks and emoji. A 5,200-byte text file and a 2 MiB binary file were sent in both directions; the files returned to Mac matched their original SHA-256 digests. Automatic acceptance was verified for text in both directions and for a file from Mac to iPhone; disabling it on Mac restored manual confirmation. A later local build cleared an unchanged text draft on verified delivery and displayed the two bulk-history confirmation dialogs on Mac.

1.3.0 additionally changes peer expiration and transient LAN fallback. These source changes are covered by automated checks; they have not yet been subjected to an extensive physical-device fault or performance campaign. The iPhone system camera opening the invitation link, public HTTPS relay deployment, 10 GiB files, background operation and difficult real-world networks remain unverified.

## Automated checks

Run the commands in [BUILDING.md](BUILDING.md). Checks exercise core storage and sender logic, pairing review, localization, icon masks, model queue and cancellation, automatic acceptance, draft protection, history deletion, stale-peer rediscovery, and local encrypted TCP and relay recovery with dropped acknowledgements and receiver restarts. CI builds an iOS simulator target and packages the Mac application. Test counts and CI status are available from the test output and GitHub Actions.

Source and package audits are targeted checks, not proof that every sensitive value is absent. Existing public Git history remains unchanged. Applications use a shared pairing secret: compromise of the secret can compromise the pairing group, and per-device revocation and forward secrecy are not provided.
