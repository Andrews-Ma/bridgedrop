# Publication checklist

- Publish only the curated source project. Exclude application data, invitations, credentials, private backups, device identifiers, signing assets and build logs.
- Review source files, images/metadata, generated resources and commit history. Deleting a file does not erase it from Git history. Use a public Git author name and noreply email.
- Include the MIT license in the source and binary downloads. Credit design references without claiming protocol interoperability or including their code under a different license.
- Run the checks in docs/BUILDING.md. Review core behavior, confirmation-before-pairing, queued cancellation, saved-file integrity and platform builds.
- Build from the intended release commit. Prepare a draft Release, attach only reviewed packages and SHA-256 checksums, and check tag, commit and attachments before publishing. Download the published package again and compare it with the local checksum.
- State actual tested platforms and remaining device/network checks. SDK compilation, simulator URL dispatch and physical-camera acceptance are different results.
- Preserve the installed app and local data before replacing it. Do not reset pairing keys during an ordinary update.
- Keep community promotion separate from repository maintenance; do not publish private planning notes, statistics or promotional drafts.
