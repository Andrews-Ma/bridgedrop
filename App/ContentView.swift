import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import BridgeDropCore
#endif

private let bridgeTint = Color(red: 0.05, green: 0.49, blue: 0.48)

struct ContentView: View {
    @AppStorage("BridgeDrop.language") private var language = "en"
    private func tr(_ value: String) -> String { BridgeLocalization.text(value, language: language) }
    @ObservedObject var model: AppModel
    @State private var showFilePicker = false
    @State private var showSettings = false
    @State private var reviewAfterSettings = false
    @State private var confirmClearOutgoing = false
    @State private var confirmClearReceived = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            #if os(macOS)
            HSplitView {
                ScrollView {
                    sendPane.padding(22)
                }
                .frame(minWidth: 330, idealWidth: 380, maxWidth: 440)
                ScrollView {
                    receivePane.padding(22)
                }
                .frame(minWidth: 360)
            }
            #else
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        if model.records.contains(where: { $0.state == .awaitingApproval }) {
                            Button {
                                withAnimation { proxy.scrollTo("incoming-requests", anchor: .top) }
                            } label: {
                                Label(tr("查看待确认的接收请求"), systemImage: "tray.and.arrow.down.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        sendPane
                        receivePane.id("incoming-requests")
                    }
                    .padding(16)
                }
            }
            #endif
        }
        .background(Color.primary.opacity(0.025))
        .tint(bridgeTint)
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 600)
        #endif
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                let scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
                defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
                model.sendFiles(urls)
            case .failure(let error):
                model.errorMessage = "无法打开文件：\(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $model.showInvite, onDismiss: { model.dismissPairingReview() }) { PairingSheet(model: model) }
        .sheet(isPresented: $showSettings, onDismiss: {
            if reviewAfterSettings { reviewAfterSettings = false; model.showInvite = true }
        }) { ConnectionSettings(model: model) }
        .onChange(of: model.pairingReviewID) { _ in
            if showSettings {
                reviewAfterSettings = true
                model.showInvite = false
                showSettings = false
            }
        }
        .alert(tr("操作未完成"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(tr(model.errorMessage ?? "请稍后重试。"))
        }
        .environment(\.locale, Locale(identifier: language == "zh" ? "zh-Hans" : "en"))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("BrandIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 46, height: 46)
                .background(bridgeTint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("轻传")).font(.title2.bold())
                Text("BridgeDrop · \(model.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { model.showInvite = true } label: {
                Label(tr("配对"), systemImage: "qrcode")
                    #if os(iOS)
                    .labelStyle(.iconOnly)
                    #endif
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(tr("设备配对"))
            Button { showSettings = true } label: {
                Label(tr("设置"), systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(tr("连接设置"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var sendPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(model.isRunning ? bridgeTint : .orange)
                    .frame(width: 8, height: 8).padding(.top, 5)
                Text(tr(model.status)).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #if os(iOS)
            if !model.isRunning {
                Button(tr("开启 / 恢复已有配对连接")) { model.start() }
                    .buttonStyle(.bordered)
                    .disabled(model.isReviewPending)
                Text(tr("打开邀请只会显示确认页。确认导入后才保存新配对并连接；已有配对可用上方按钮恢复。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif

            BridgePanel(title: tr("发送到"), symbol: "laptopcomputer.and.iphone") {
                if model.nearby.isEmpty {
                    EmptyHint(symbol: "antenna.radiowaves.left.and.right", title: tr("等待另一台设备"),
                              detail: tr("在两台设备上打开轻传，先完成配对。同一局域网中会自动发现设备。"))
                    Button(tr("配对设备")) { model.showInvite = true }
                        .buttonStyle(.borderedProminent)
                    DisclosureGroup(tr("连接诊断")) {
                        Text(tr("请让两端轻传保持打开，检查本地网络权限和 Wi-Fi 是否互通。访客网络可能阻止设备互访；自动发现失败时可在设置中使用对方的局域网地址。不同网络需配置中继。"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(tr("打开连接设置")) { showSettings = true }.buttonStyle(.bordered)
                    }
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.nearby) { peer in
                            Button { model.selectPeer(peer) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "network")
                                        .frame(width: 32, height: 32)
                                        .background(bridgeTint.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(peer.name).font(.subheadline.weight(.semibold))
                                        Text(tr(peer.detail)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: model.selectedPeerID == peer.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(model.selectedPeerID == peer.id ? bridgeTint : .secondary)
                                }
                                .padding(10)
                                .background(model.selectedPeerID == peer.id ? bridgeTint.opacity(0.08) : Color.primary.opacity(0.025),
                                            in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(tr("发送到 \(peer.name)"))
                            .accessibilityAddTraits(model.selectedPeerID == peer.id ? .isSelected : [])
                        }
                    }
                }
            }

            BridgePanel(title: tr("文件"), symbol: "doc.on.doc") {
                Text(tr("对方确认后开始传输；短暂断网会自动尝试从断点恢复。最多同时传输两个任务。"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { showFilePicker = true } label: {
                    Label(tr("选择文件并发送"), systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.selectedPeerID == nil)
            }

            BridgePanel(title: tr("文字"), symbol: "text.alignleft") {
                Text(tr("主动粘贴要发送的内容；收到后再点击复制。"))
                    .font(.subheadline).foregroundStyle(.secondary)
                TextEditor(text: $model.textDraft)
                    .font(.body)
                    .frame(minHeight: 110, maxHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.09)))
                    .accessibilityLabel(tr("要发送的文本"))
                HStack {
                    PasteButton(payloadType: String.self) { items in
                        model.textDraft = items.joined(separator: "\n")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Text(tr("\(model.textDraft.utf8.count.formatted()) 字节"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button { model.sendText() } label: {
                        Label(tr("发送"), systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedPeerID == nil || model.textDraft.isEmpty)
                }
            }

            if !model.outgoing.isEmpty {
                BridgePanel(title: tr("发送记录"), symbol: "arrow.up.circle") {
                    if model.hasRemovableOutgoing {
                        HStack { Spacer(); Button(tr("清除所有发送记录")) { confirmClearOutgoing = true }.buttonStyle(.borderless) }
                    }
                    VStack(spacing: 14) {
                        ForEach(model.outgoing) { transfer in
                            OutgoingRow(transfer: transfer,
                                        retry: { model.retry(transfer) },
                                        cancel: { model.cancel(transfer) },
                                        remove: { model.removeOutgoingHistory(transfer) })
                        }
                    }
                }
                .confirmationDialog(tr("清除所有已结束的发送记录？"), isPresented: $confirmClearOutgoing, titleVisibility: .visible) {
                    Button(tr("清除记录"), role: .destructive) { model.clearOutgoingHistory() }
                    Button(tr("取消"), role: .cancel) {}
                } message: { Text(tr("仅清除已结束的记录；进行中和可继续的传输会保留。")) }
            }
        }
    }

    private var receivePane: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(tr("接收")).font(.title2.bold())
                Spacer()
                Toggle(tr("自动接收"), isOn: $model.autoAcceptEnabled)
                    .toggleStyle(.switch)
                    .font(.caption)
            }
            if model.autoAcceptEnabled {
                Text(tr("已配对设备的新请求会自动接收；文字不会自动覆盖剪贴板。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(tr("配对组共享密钥；如邀请码或密钥泄露，请移除配对并重新配对。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let pending = model.records.filter { $0.state == .awaitingApproval }
            if !pending.isEmpty {
                BridgePanel(title: tr("等待你的确认"), symbol: "tray.and.arrow.down") {
                    VStack(spacing: 16) {
                        ForEach(pending) { record in
                            VStack(alignment: .leading, spacing: 10) {
                                RecordHeading(record: record)
                                HStack {
                                    Button(tr("拒绝"), role: .destructive) { model.reject(record) }
                                        .buttonStyle(.bordered)
                                    Spacer()
                                    Button(tr("接收")) { model.approve(record) }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                            if record.id != pending.last?.id { Divider() }
                        }
                    }
                }
            }

            let history = model.records.filter { $0.state != .awaitingApproval }
            BridgePanel(title: tr("收到的内容"), symbol: "tray.full") {
                if history.isEmpty {
                    EmptyHint(symbol: "tray", title: tr("这里还没有内容"),
                              detail: tr("对方发送后，接收请求会出现在这里。文字不会自动覆盖你的剪贴板。"))
                } else {
                    if model.hasRemovableReceived {
                        HStack { Spacer(); Button(tr("清除所有接收记录")) { confirmClearReceived = true }.buttonStyle(.borderless) }
                    }
                    VStack(spacing: 18) {
                        ForEach(history) { record in
                            ReceivedRow(record: record,
                                        copy: { model.copyText(record) },
                                        reveal: { model.reveal(record) },
                                        remove: { model.removeReceivedHistory(record) })
                            if record.id != history.last?.id { Divider() }
                        }
                    }
                }
            }
            .confirmationDialog(tr("清除所有已结束的接收记录？"), isPresented: $confirmClearReceived, titleVisibility: .visible) {
                Button(tr("清除记录"), role: .destructive) { model.clearReceivedHistory() }
                Button(tr("取消"), role: .cancel) {}
            } message: { Text(tr("仅从列表移除已结束的记录；待确认、进行中的传输、已保存文件及恢复数据会保留。")) }
            Text(tr("iPhone 传输期间请保持轻传在前台。网络中断后，可以重新打开应用并重试发送。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct BridgePanel<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct EmptyHint: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light))
                .foregroundStyle(bridgeTint.opacity(0.65))
                .padding(.bottom, 4)
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }
}

private struct RecordHeading: View {
    @AppStorage("BridgeDrop.language") private var language = "en"
    private func tr(_ value: String) -> String { BridgeLocalization.text(value, language: language) }
    let record: TransferRecord
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.manifest.kind == .text ? "text.bubble" : "doc")
                .font(.title3).foregroundStyle(bridgeTint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(record.manifest.kind == .text ? tr("文本") : record.manifest.name).font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(tr("来自 \(record.manifest.senderName) · \(formatBytes(record.manifest.byteCount))"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            Text(record.manifest.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct OutgoingRow: View {
    @AppStorage("BridgeDrop.language") private var language = "en"
    private func tr(_ value: String) -> String { BridgeLocalization.text(value, language: language) }
    let transfer: OutgoingTransfer
    let retry: () -> Void
    let cancel: () -> Void
    let remove: () -> Void
    @State private var confirmRemove = false

    private var canRetry: Bool {
        guard !["准备文件", "准备失败", "已送达"].contains(transfer.state) else { return false }
        return ["可继续", "已取消", "需重新发送", "发送失败"].contains(transfer.state)
    }

    private var canCancel: Bool {
        guard !["准备文件", "准备失败", "已送达", "需重新发送"].contains(transfer.state) else { return false }
        return !["完成", "成功", "取消", "拒绝", "失败"].contains(where: transfer.state.contains)
    }

    private var retryLabel: String {
        if ["已取消", "需重新发送"].contains(transfer.state) { return "重新发送" }
        if transfer.state == "可继续" { return "继续" }
        return "重试"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(transfer.kind == .text ? tr("文本") : transfer.name).font(.subheadline.weight(.medium)).lineLimit(2)
                Spacer()
                Text(tr(transfer.state)).font(.caption).foregroundStyle(.secondary)
            }
            if transfer.state == "准备文件" {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("正在暂存文件，请稍候…")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ProgressView(value: min(max(transfer.progress, 0), 1))
            }
            if let error = transfer.error {
                Text(tr(error)).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if transfer.state == "准备失败" {
                Text(tr("请重新选择文件发送。")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("\(Int(min(max(transfer.progress, 0), 1) * 100))%")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                if canRetry { Button(tr(retryLabel), action: retry).buttonStyle(.bordered) }
                if canCancel { Button(tr("取消"), role: .cancel, action: cancel).buttonStyle(.borderless) }
                if ["已送达", "已取消", "需重新发送", "发送失败", "准备失败"].contains(transfer.state) {
                    Button(tr("删除记录")) { confirmRemove = true }.buttonStyle(.borderless)
                }
            }
        }
        .confirmationDialog(tr("删除这条记录？"), isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(tr("删除记录"), role: .destructive, action: remove)
            Button(tr("取消"), role: .cancel) {}
        } message: { Text(tr("仅从列表移除；已保存文件和传输恢复所需的数据会保留。")) }
    }
}

private struct ReceivedRow: View {
    @AppStorage("BridgeDrop.language") private var language = "en"
    private func tr(_ value: String) -> String { BridgeLocalization.text(value, language: language) }
    let record: TransferRecord
    let copy: () -> Void
    let reveal: () -> Void
    let remove: () -> Void
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecordHeading(record: record)
            if record.state == .receiving {
                ProgressView(value: Double(record.receivedBytes) / Double(max(record.manifest.byteCount, 1)))
                Text(tr("正在接收 · \(formatBytes(record.receivedBytes)) / \(formatBytes(record.manifest.byteCount))"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if record.state == .completed {
                if let text = record.text {
                    Text(text).font(.subheadline).lineLimit(6).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    Button(action: copy) { Label(tr("复制文字"), systemImage: "doc.on.doc") }
                        .buttonStyle(.bordered)
                } else if let path = record.localPath {
                    HStack {
                        #if os(macOS)
                        Button(action: reveal) { Label(tr("在访达中显示"), systemImage: "folder") }
                            .buttonStyle(.bordered)
                        #endif
                        ShareLink(item: URL(fileURLWithPath: path)) {
                            Label(tr("分享 / 保存"), systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Label(tr("已保存并校验"), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(bridgeTint)
            } else {
                Text(tr(stateLabel(record.state))).font(.caption).foregroundStyle(.secondary)
            }
            if let error = record.error {
                Text(tr(error)).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if record.state != .receiving {
                Button(tr("删除记录")) { confirmRemove = true }.buttonStyle(.borderless)
            }
        }
        .confirmationDialog(tr("删除这条记录？"), isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(tr("删除记录"), role: .destructive, action: remove)
            Button(tr("取消"), role: .cancel) {}
        } message: { Text(tr("仅从列表移除；已保存文件和传输恢复所需的数据会保留。")) }
    }

    private func stateLabel(_ state: TransferState) -> String {
        switch state {
        case .awaitingApproval: return "等待确认"
        case .receiving: return "正在接收"
        case .completed: return "已完成"
        case .rejected: return "已拒绝"
        case .cancelled: return "已取消"
        case .failed: return "接收失败，请对方重新发送"
        }
    }
}

private struct PairingSheet: View {
    @AppStorage("BridgeDrop.language") private var language = "en"
    private func tr(_ value: String) -> String { BridgeLocalization.text(value, language: language) }
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmedReviewID: UUID?
    @State private var confirmedDraft: String?

    private var confirmsCurrentInvite: Bool {
        confirmedReviewID == model.pairingReviewID && confirmedDraft == model.pairingDraft
    }
    private func clearConfirmation() { confirmedReviewID = nil; confirmedDraft = nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(tr("不同 Apple 账户也能连接。只在你信任的两台设备之间交换邀请码。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    Picker(tr("配对方式"), selection: $model.pairingMode) {
                        Text(tr("本机邀请码")).tag(0)
                        Text(tr("导入邀请码")).tag(1)
                    }
                    .pickerStyle(.segmented)

                    if model.pairingMode == 0 {
                        ownInvite
                    } else {
                        importInvite
                    }
                }
                .padding(22)
            }
            .navigationTitle(tr("设备配对"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(tr("完成")) { dismiss() } }
            }
        }
        .tint(bridgeTint)
        #if os(macOS)
        .frame(width: 550, height: 710)
        #endif
        .onAppear { model.refreshInvite() }
        .onChange(of: model.pairingReviewID) { _ in clearConfirmation() }
        .onChange(of: model.pairingDraft) { _ in
            clearConfirmation()
            model.reviewPairingDraft()
        }
        #if os(iOS)
        .sheet(isPresented: $model.scanning) {
            NavigationStack {
                QRScanner { value in
                    clearConfirmation()
                    model.receivePairingInput(value)
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(tr("扫描邀请码"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(tr("取消")) { model.scanning = false }
                    }
                }
            }
        }
        #endif
    }

    private var ownInvite: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(tr("请先在 iPhone 安装并打开“轻传”"), systemImage: "iphone")
                .font(.headline)
            Text(tr("安装轻传后，可用 iPhone 系统相机扫描下方二维码，并点击出现的轻传应用链接。打开后核对设备信息，再确认导入。"))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Label(tr("若系统相机没有提供打开轻传的入口，请在轻传内进入“配对 → 导入邀请码 → 扫描另一台设备”，或使用文本导入。"), systemImage: "info.circle")
                .font(.subheadline).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if !model.isRunning {
                Button(tr("启用本机连接并显示邀请码")) {
                    model.dismissPairingReview()
                    model.start()
                }.buttonStyle(.bordered)
            } else if let qr = PairingQRCode.image(for: model.inviteLink) {
                Image(decorative: qr, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 300, maxHeight: 300)
                    .padding(16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(tr("本机设备配对二维码"))
            }
            Label(tr("邀请码包含配对密钥，请勿公开、外发或上传到公开二维码网站。"), systemImage: "lock.fill")
                .font(.subheadline).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text(tr("分享或复制的应用链接只能交给轻传处理；也可在轻传中粘贴旧版 JSON 邀请码。不要提交到搜索框、浏览器地址栏或公开二维码解析网站。"))
                .font(.subheadline).foregroundStyle(.secondary)
            DisclosureGroup(tr("显示邀请码文本")) {
                Text(model.isRunning ? model.inviteLink : tr("启用本机连接后显示应用链接。"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }
            HStack {
                ShareLink(item: model.inviteLink) {
                    Label(tr("分享邀请链接（仅轻传处理）"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(!model.isRunning || model.inviteLink.isEmpty)
                Spacer()
                Button(tr("刷新显示")) { model.refreshInvite() }.buttonStyle(.bordered)
            }
            Text(tr("刷新显示只更新有效时间，不会更换密钥。邀请码若被搜索或外发，请在“设置 → 移除配对”中更换密钥，再重新配对。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var importInvite: some View {
        VStack(alignment: .leading, spacing: 14) {
            #if os(iOS)
            Button { model.scanning = true } label: {
                Label(tr("扫描另一台设备"), systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            #endif
            Text(tr("粘贴轻传应用链接或旧版 JSON 邀请码"))
                .font(.subheadline.weight(.semibold))
            TextEditor(text: $model.pairingDraft)
                .font(.caption.monospaced())
                .frame(minHeight: 150)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel(tr("邀请码文本"))
            PasteButton(payloadType: String.self) { items in
                clearConfirmation()
                model.receivePairingInput(items.joined(separator: "\n"))
            }
            .buttonStyle(.bordered)
            if let invitation = model.pairingPreview {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("邀请来自：\(invitation.inviterName)")).font(.headline)
                    Text(tr("设备 ID：\(invitation.inviterID)")).font(.caption.monospaced())
                    Text(tr("连接地址：\(invitation.host):\(invitation.port)")).font(.caption)
                    Text(tr("有效至：\(Date(timeIntervalSince1970: invitation.expiresAt).formatted())")).font(.caption)
                    if let relay = invitation.relayURL, !relay.isEmpty {
                        Text(tr("中继服务：\(relay)")).font(.caption).lineLimit(2)
                    }
                    Text(tr("确认后会在本机保存此配对，并尝试连接该设备。当前尚未导入，也未验证设备在线。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let message = model.pairingValidationMessage {
                Text(tr(message)).font(.subheadline).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(tr("导入后，对方持有的密钥可用于与你的设备建立连接。请确认邀请码来自你信任的设备。"), systemImage: "lock.shield")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(tr("我确认这是我信任的设备，且邀请码未公开外发"), isOn: Binding(
                get: { confirmsCurrentInvite },
                set: { confirmedReviewID = $0 ? model.pairingReviewID : nil; confirmedDraft = $0 ? model.pairingDraft : nil }
            ))
                .font(.subheadline)
            Button {
                if confirmsCurrentInvite && model.importInvite(model.pairingDraft) { dismiss() }
            } label: {
                Label(tr("确认导入并配对"), systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.pairingPreview == nil || !confirmsCurrentInvite)
        }
    }

}

private struct ConnectionSettings: View {
    @AppStorage("BridgeDrop.language") private var language = "en"
    private func tr(_ value: String) -> String { BridgeLocalization.text(value, language: language) }
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForget = false
    @State private var initialName = ""
    @State private var initialRelayURL = ""
    @State private var initialRelayToken = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(tr("语言")) {
                    Picker(tr("界面语言"), selection: $language) {
                        Text("English").tag("en")
                        Text("简体中文").tag("zh")
                    }
                }
                Section(tr("本机名称")) {
                    TextField(tr("例如：我的 MacBook"), text: $model.name)
                }
                Section {
                    TextField(tr("IP 地址，例如 192.168.1.8"), text: $model.manualHost)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                    TextField(tr("端口"), text: $model.manualPort)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Button(tr("按地址连接")) { model.connectManual() }
                        .disabled(model.manualHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text(tr("手动连接"))
                } footer: {
                    Text(tr("自动发现失败时，输入另一台设备的局域网 IP。两台设备仍需完成配对。"))
                }
                Section {
                    TextField(tr("HTTPS 服务地址"), text: $model.relayURL)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        #endif
                    SecureField(tr("中继访问令牌"), text: $model.relayToken)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    Button(tr("保存设置")) { model.saveRelay() }
                } header: {
                    Text(tr("跨网络中继（可选）"))
                } footer: {
                    Text(tr("不同网络传输需要你部署或指定可访问的中继服务，并在两台设备上配置相同地址和令牌。文件与文字的内容在设备端加密。"))
                }
                Section {
                    Button(tr("移除配对"), role: .destructive) { confirmForget = true }
                } footer: {
                    Text(tr("移除配对会生成新密钥，使旧邀请码及旧配对失效。已收到的文件保留，两台设备需要重新配对。"))
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(tr("连接设置"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("完成")) {
                        if model.name != initialName || model.relayURL != initialRelayURL || model.relayToken != initialRelayToken { model.saveRelay() }
                        dismiss()
                    }
                }
            }
        }
        .tint(bridgeTint)
        .onAppear { initialName = model.name; initialRelayURL = model.relayURL; initialRelayToken = model.relayToken }
        #if os(macOS)
        .frame(width: 550, height: 660)
        #endif
        .confirmationDialog(tr("移除当前设备配对？"), isPresented: $confirmForget, titleVisibility: .visible) {
            Button(tr("移除配对"), role: .destructive) { model.forgetPairing() }
            Button(tr("取消"), role: .cancel) {}
        } message: {
            Text(tr("此操作会移除连接凭据。重新配对后才能继续传输。"))
        }
    }
}

private func formatBytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}
