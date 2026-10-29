import Foundation
import Vision

private struct CheckFailed: Error {}

@main struct PairingChecks {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("FAIL: pairing regression check. Invitation contents are intentionally omitted.\n", stderr); exit(1) }
    }

    @MainActor static func run() async throws {
        var passed = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { print("FAIL: " + label); throw CheckFailed() }
            passed += 1; print("PASS: " + label)
        }
        let ownID = "11111111-1111-4111-8111-111111111111"
        let senderID = "22222222-2222-4222-8222-222222222222"
        // Entirely synthetic, short-lived fixtures. Never load live Keychain credentials.
        func fixture(expires: Double = Date().addingTimeInterval(1800).timeIntervalSince1970) throws -> String {
            let invitation = PairInvitation(format: "bridgedrop-invite-v1", pairID: String(repeating: "a", count: 32),
                                            secret: Data(repeating: 7, count: 32).base64EncodedString(),
                                            inviterID: senderID, inviterName: "测试 Mac · été 📱", host: "192.168.1.10", port: 47185,
                                            relayURL: nil, relayToken: nil, expiresAt: expires)
            return String(data: try JSONEncoder().encode(invitation), encoding: .utf8)!
        }
        func changed(_ json: String, _ field: String, _ value: Any) throws -> String {
            var object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
            object[field] = value
            return String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }
        func rejected(_ text: String) -> Bool {
            do { _ = try PairingInviteCodec.preview(text, ownDeviceID: ownID); return false }
            catch { return true }
        }
        let raw = try fixture()
        let url = try PairingInviteCodec.link(for: raw)
        let link = url.absoluteString
        let parsed = try PairingInviteCodec.preview(link, ownDeviceID: ownID)
        try check(url.scheme == PairingInviteCodec.scheme && url.host == "pair" && !link.hasPrefix("{"), "generated invitation is an app URL")
        try check(parsed.rawJSON == raw && parsed.invitation.inviterID == senderID, "link payload round-trips unchanged")
        try check(try PairingInviteCodec.preview(raw, ownDeviceID: ownID).rawJSON == raw, "legacy raw JSON remains supported")
        try check(try PairingInviteCodec.preview(" \n" + link + "\n ", ownDeviceID: ownID).invitation.inviterName == parsed.invitation.inviterName,
                  "Unicode device name and surrounding whitespace")

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let payload = components.queryItems!.first { $0.name == "payload" }!.value!
        func make(_ items: [URLQueryItem], mutate: (inout URLComponents) -> Void = { _ in }) -> String {
            var value = components; value.queryItems = items; mutate(&value); return value.string!
        }
        let ordinary = components.queryItems!
        let invalidLinks: [(String, String)] = [
            (make(ordinary, mutate: { $0.scheme = "https" }), "wrong scheme"),
            (make(ordinary, mutate: { $0.host = "other" }), "wrong host"),
            (make(ordinary, mutate: { $0.path = "/extra" }), "unexpected path"),
            (make(ordinary, mutate: { $0.path = "/" }), "unexpected trailing slash"),
            (make(ordinary, mutate: { $0.user = "user" }), "URL credentials"),
            (make(ordinary, mutate: { $0.port = 47185 }), "HTTP-style port misuse"),
            (make(ordinary, mutate: { $0.fragment = "fragment" }), "fragment"),
            (make([URLQueryItem(name: "payload", value: payload)]), "missing version"),
            (make([URLQueryItem(name: "v", value: "1")]), "missing payload"),
            (make([URLQueryItem(name: "v", value: "2"), URLQueryItem(name: "payload", value: payload)]), "unsupported version"),
            (make(ordinary + [URLQueryItem(name: "v", value: "1")]), "duplicate version"),
            (make(ordinary + [URLQueryItem(name: "payload", value: payload)]), "duplicate payload"),
            (make(ordinary + [URLQueryItem(name: "extra", value: "1")]), "unknown parameter"),
            (make([URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "payload", value: nil)]), "nil payload"),
            (make([URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "payload", value: "")]), "empty payload"),
            (make([URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "payload", value: "A")]), "invalid Base64URL length"),
            (make([URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "payload", value: "abc=")]), "padding is not canonical Base64URL"),
            (make([URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "payload", value: "ab+c/")]), "standard Base64 characters rejected"),
            (make([URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "payload", value: "Zh")]), "noncanonical trailing pad bits"),
            (make([URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "payload", value: "_w")]), "non UTF-8 / malformed JSON"),
            (make([URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "payload", value: String(repeating: "A", count: PairingInviteCodec.maximumPayloadBytes + 1))]), "oversized payload"),
            (String(repeating: "A", count: PairingInviteCodec.maximumInputBytes + 1), "oversized input"),
            ("{", "truncated JSON"), ("{}", "missing JSON fields"),
            (try changed(raw, "expiresAt", Date().addingTimeInterval(-30).timeIntervalSince1970), "expired invitation"),
            (try changed(raw, "expiresAt", Date().addingTimeInterval(7200).timeIntervalSince1970), "expiry exceeds existing window"),
            (try changed(raw, "format", "tampered"), "tampered invitation format"),
            (try changed(raw, "secret", Data(repeating: 0, count: 31).base64EncodedString()), "tampered key length"),
            (try changed(raw, "inviterID", "invalid"), "tampered device ID"),
            (try changed(raw, "inviterID", ownID), "self pairing"),
            (try changed(raw, "pairID", "invalid"), "tampered pair ID"),
            (try changed(raw, "port", 0), "invalid transfer port")
        ]
        for (input, label) in invalidLinks { try check(rejected(input), label) }
        // Corrupt only unused Base64 pad bits of otherwise valid invitation JSON.
        var padRaw = raw
        while Data(padRaw.utf8).count % 3 == 0 { padRaw += " " }
        var padURL = URLComponents(url: try PairingInviteCodec.link(for: padRaw), resolvingAgainstBaseURL: false)!
        var padPayload = padURL.queryItems!.first { $0.name == "payload" }!.value!
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let lastIndex = alphabet.firstIndex(of: padPayload.last!)!
        padPayload.removeLast(); padPayload.append(alphabet[lastIndex + 1])
        padURL.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "payload", value: padPayload)]
        var rejectedPadBits = false
        do { _ = try PairingInviteCodec.preview(padURL.string!, ownDeviceID: ownID) }
        catch InviteInputError.invalidPayload { rejectedPadBits = true }
        catch { }
        try check(rejectedPadBits, "noncanonical encoding of valid JSON is specifically rejected before JSON decode")
        let expiredLink = try PairingInviteCodec.link(for: fixture(expires: Date().addingTimeInterval(-1).timeIntervalSince1970)).absoluteString
        try check(rejected(expiredLink), "expired linked invitation uses unchanged vault validation")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("bridgedrop-pairing-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let existing = PairConfiguration(pairID: String(repeating: "b", count: 32), secret: Data(repeating: 3, count: 32),
                                         relayURL: "", relayToken: "", trustedNames: [senderID: "已有配对"],
                                         preferredHost: "192.168.1.99", preferredPort: 47185)
        var existingWrites = 0
        let existingModel = AppModel(deviceID: ownID, dataRoot: temporary.appendingPathComponent("existing"),
                                    loadPairing: { existing }, savePairing: { _ in existingWrites += 1 })
        existingModel.receivePairingInput(link)
        existingModel.refreshInvite()
        let unchanged = try JSONDecoder().decode(PairInvitation.self, from: Data(existingModel.inviteText.utf8))
        try check(existingWrites == 0 && !existingModel.isRunning && unchanged.pairID == existing.pairID
                  && unchanged.secret == existing.secret.base64EncodedString() && existingModel.manualHost == existing.preferredHost,
                  "preview preserves an existing pairing and configured address")
        var saveAttempts = 0
        let saveFailureModel = AppModel(deviceID: ownID, dataRoot: temporary.appendingPathComponent("save-failure"),
                                       loadPairing: { existing }, savePairing: { _ in saveAttempts += 1; throw CheckFailed() })
        saveFailureModel.receivePairingInput(link)
        try check(!saveFailureModel.importInvite(raw) && saveAttempts == 1 && !saveFailureModel.isRunning
                  && saveFailureModel.selectedPeerID == nil && saveFailureModel.manualHost == existing.preferredHost,
                  "failed confirmed save never changes trust or starts connection")
        var writes = 0
        let model = AppModel(deviceID: ownID, dataRoot: temporary,
                             loadPairing: { nil }, savePairing: { _ in writes += 1 })
        try check(writes == 0 && !model.isRunning, "cold model initialization never saves or connects")
        model.receivePairingInput(link)
        try check(model.showInvite && model.pairingMode == 1 && model.pairingPreview?.inviterID == senderID && model.pairingDraft == raw,
                  "external link opens prefilled import review")
        try check(writes == 0 && !model.isRunning && model.nearby.isEmpty && model.selectedPeerID == nil,
                  "preview does not save trust or connect")
        model.start()
        try check(writes == 0 && !model.isRunning, "pending review blocks accidental scene startup")
        let firstReview = model.pairingReviewID
        model.receivePairingInput(link)
        try check(firstReview != model.pairingReviewID, "same link delivered again invalidates UI confirmation")
        model.receivePairingInput(raw)
        try check(model.pairingPreview?.inviterID == senderID && writes == 0, "in-app legacy scan stages review without saving")
        for (input, _) in invalidLinks {
            model.receivePairingInput(input)
            guard model.pairingPreview == nil, model.pairingValidationMessage != nil, writes == 0, !model.isRunning else { throw CheckFailed() }
            guard !model.importInvite(input), writes == 0, !model.isRunning else { throw CheckFailed() }
        }
        try check(true, "all malformed inputs clear stale preview and cannot commit or connect")
        let soonExpired = try fixture(expires: Date().addingTimeInterval(0.2).timeIntervalSince1970)
        model.receivePairingInput(soonExpired)
        try check(model.pairingPreview != nil, "short-lived invitation initially previews")
        try await Task.sleep(nanoseconds: 300_000_000)
        try check(!model.importInvite(soonExpired) && writes == 0 && !model.isRunning, "expiry is rechecked at confirmation before saving")
        model.refreshInvite()
        guard let image = PairingQRCode.image(for: model.inviteLink) else { throw CheckFailed() }
        let detector = VNDetectBarcodesRequest(); detector.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([detector])
        try check(detector.results?.first?.payloadStringValue == model.inviteLink && model.inviteLink.hasPrefix(PairingInviteCodec.scheme + "://pair?"),
                  "actual UI QR generator decodes to the app link, not JSON")
        try check(writes == 0 && !model.isRunning, "generating and inspecting QR is side-effect free")
        print("Pairing checks: \(passed)/\(passed) passed. No live Keychain data or device connections used.")
    }
}
