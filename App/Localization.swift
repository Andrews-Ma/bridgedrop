import Foundation

/// Translates interface copy at the presentation boundary. Persisted states and user content remain unchanged.
enum BridgeLocalization {
    static func text(_ value: String, language: String) -> String {
        guard !language.lowercased().hasPrefix("zh") else { return value }
        if let exact = english[value] { return exact }
        for (prefix, translated) in prefixes where value.hasPrefix(prefix) {
            return translated + String(value.dropFirst(prefix.count))
        }
        if value.hasSuffix(" 字节") { return String(value.dropLast(" 字节".count)) + " bytes" }
        if value.hasPrefix("正在自动重试（"), let end = value.range(of: "/4），已保存的数据会从断点继续。") {
            let count = value[value.index(value.startIndex, offsetBy: "正在自动重试（".count)..<end.lowerBound]
            return "Retrying automatically (\(count)/4). Saved data will resume from the last offset."
        }
        if value.hasPrefix("无法读取本机钥匙串中的配对信息（"), value.hasSuffix("）。") {
            return "Could not read pairing information from Keychain (" + value.dropFirst("无法读取本机钥匙串中的配对信息（".count).dropLast(2) + ")."
        }
        for (prefix, englishPrefix) in [("保存配对信息失败（", "Could not save pairing information ("), ("保存本机配对密钥失败（", "Could not save the pairing key (")] where value.hasPrefix(prefix) && value.hasSuffix("）。") {
            return englishPrefix + value.dropFirst(prefix.count).dropLast(2) + ")."
        }
        return value
    }
    static func current(_ value: String) -> String {
        text(value, language: UserDefaults.standard.string(forKey: "BridgeDrop.language") ?? "en")
    }
    private static let prefixes: [(String, String)] = [
        ("无法打开文件：", "Could not open file: "),
        ("无法保存发送进度：", "Could not save send progress: "),
        ("局域网接收未开启：", "LAN receiving could not start: "),
        ("局域网接收失败：", "LAN receiving failed: "),
        ("配对信息已保存，正在连接 ", "Pairing saved; connecting to "),
        ("服务器返回错误 ", "Server returned error "),
        ("发送到 ", "Send to "), ("来自 ", "From "),
        ("正在接收 · ", "Receiving · "),
        ("邀请来自：", "Invitation from: "), ("设备 ID：", "Device ID: "),
        ("连接地址：", "Connection address: "), ("有效至：", "Expires: "),
        ("中继服务：", "Relay service: ")
    ]
    private static let english: [String: String] = [
        "语言": "Language", "界面语言": "Interface language",
        "轻传": "BridgeDrop", "配对": "Pair", "设备配对": "Pair devices", "设置": "Settings", "连接设置": "Connection settings",
        "操作未完成": "Action could not be completed", "知道了": "OK", "请稍后重试。": "Please try again later.",
        "开启 / 恢复已有配对连接": "Enable / restore paired connection",
        "打开邀请只会显示确认页。确认导入后才保存新配对并连接；已有配对可用上方按钮恢复。": "Opening an invitation only displays a review page. A new pairing is saved and connected only after confirmation; use the button above to restore an existing pairing.",
        "发送到": "Send to", "等待另一台设备": "Waiting for another device",
        "在两台设备上打开轻传，先完成配对。同一局域网中会自动发现设备。": "Open BridgeDrop on both devices and complete pairing. Devices on the same reachable network can be discovered automatically.",
        "配对设备": "Pair devices", "文件": "Files", "文字": "Text", "文本": "Text",
        "连接诊断": "Connection help", "打开连接设置": "Open connection settings", "请让两端轻传保持打开，检查本地网络权限和 Wi-Fi 是否互通。访客网络可能阻止设备互访；自动发现失败时可在设置中使用对方的局域网地址。不同网络需配置中继。": "Keep BridgeDrop open on both devices and check local network permission and Wi-Fi connectivity. Guest networks may isolate devices. If discovery fails, enter the other device's LAN address in Settings. Different networks require a configured relay.", "配对组共享密钥；如邀请码或密钥泄露，请移除配对并重新配对。": "The paired group shares a key. If an invitation or key is exposed, remove the pairing and pair again.",
        "清除所有发送记录": "Clear outgoing history", "清除所有接收记录": "Clear received history", "清除所有已结束的发送记录？": "Clear finished outgoing history?", "清除所有已结束的接收记录？": "Clear finished received history?", "清除记录": "Clear history", "仅清除已结束的记录；进行中和可继续的传输会保留。": "Only finished entries are removed. Active and resumable transfers remain.", "仅从列表移除已结束的记录；待确认、进行中的传输、已保存文件及恢复数据会保留。": "Only finished entries are removed from the list. Pending and active transfers, saved files, and recovery data remain.",
        "自动接收": "Auto-accept", "已配对设备的新请求会自动接收；文字不会自动覆盖剪贴板。": "New requests from paired devices are accepted automatically. Received text never replaces your clipboard.", "查看待确认的接收请求": "View incoming requests", "删除记录": "Remove from history", "删除这条记录？": "Remove this entry?", "传输仍在结束，请稍后再删除记录。": "The transfer is still stopping. Try removing it again shortly.", "仅从列表移除；已保存文件和传输恢复所需的数据会保留。": "This removes the entry from the list. Saved files and data needed for transfer recovery are retained.",
        "对方确认后开始传输；短暂断网会自动尝试从断点恢复。最多同时传输两个任务。": "Transfer starts after the other device accepts. Brief interruptions are retried from the saved offset. Up to two transfers run at once.",
        "选择文件并发送": "Choose files and send", "主动粘贴要发送的内容；收到后再点击复制。": "Paste the text to send. Copy received text when you choose.",
        "要发送的文本": "Text to send", "发送": "Send", "发送记录": "Outgoing transfers", "接收": "Receive", "接收前需确认": "Approval required",
        "等待你的确认": "Awaiting your approval", "拒绝": "Decline", "收到的内容": "Received", "这里还没有内容": "Nothing received yet",
        "对方发送后，接收请求会出现在这里。文字不会自动覆盖你的剪贴板。": "Incoming requests appear here. Received text never automatically replaces your clipboard.",
        "iPhone 传输期间请保持轻传在前台。网络中断后，可以重新打开应用并重试发送。": "Keep BridgeDrop in the foreground on iPhone during transfers. After an interruption, reopen the app and retry.",
        "重新发送": "Send again", "继续": "Resume", "重试": "Retry", "取消": "Cancel", "完成": "Done",
        "正在暂存文件，请稍候…": "Preparing a local copy…", "请重新选择文件发送。": "Choose the file again to send it.",
        "复制文字": "Copy text", "在访达中显示": "Show in Finder", "分享 / 保存": "Share / Save", "已保存并校验": "Saved and verified",
        "等待确认": "Awaiting approval", "正在接收": "Receiving", "已完成": "Completed", "已拒绝": "Declined", "已取消": "Cancelled", "接收失败，请对方重新发送": "Receive failed; ask the sender to send again",
        "不同 Apple 账户也能连接。只在你信任的两台设备之间交换邀请码。": "Different Apple accounts can connect. Exchange invitations only between devices you trust.",
        "配对方式": "Pairing method", "本机邀请码": "This device's invitation", "导入邀请码": "Import invitation", "扫描邀请码": "Scan invitation",
        "请先在 iPhone 安装并打开“轻传”": "Install and open BridgeDrop on the iPhone first",
        "安装轻传后，可用 iPhone 系统相机扫描下方二维码，并点击出现的轻传应用链接。打开后核对设备信息，再确认导入。": "After installing BridgeDrop, scan this QR code with the iPhone camera and tap the app link if offered. Review the device details before confirming.",
        "若系统相机没有提供打开轻传的入口，请在轻传内进入“配对 → 导入邀请码 → 扫描另一台设备”，或使用文本导入。": "If the camera does not offer to open BridgeDrop, use Pair → Import invitation → Scan another device in BridgeDrop, or paste the invitation.",
        "启用本机连接并显示邀请码": "Enable connection and show invitation", "本机设备配对二维码": "This device's pairing QR code",
        "邀请码包含配对密钥，请勿公开、外发或上传到公开二维码网站。": "The invitation contains a pairing key. Do not publish it or upload it to a public QR website.",
        "分享或复制的应用链接只能交给轻传处理；也可在轻传中粘贴旧版 JSON 邀请码。不要提交到搜索框、浏览器地址栏或公开二维码解析网站。": "Open shared or copied links only in BridgeDrop. Legacy JSON invitations can also be pasted in BridgeDrop. Do not submit them to search, browsers or public QR decoders.",
        "显示邀请码文本": "Show invitation text", "启用本机连接后显示应用链接。": "Enable the connection to show the app link.",
        "分享邀请链接（仅轻传处理）": "Share invitation link (BridgeDrop only)", "刷新显示": "Refresh invitation",
        "刷新显示只更新有效时间，不会更换密钥。邀请码若被搜索或外发，请在“设置 → 移除配对”中更换密钥，再重新配对。": "Refreshing only extends the expiry; it does not change the key. If an invitation was exposed, use Settings → Remove pairing to change the key, then pair again.",
        "扫描另一台设备": "Scan another device", "粘贴轻传应用链接或旧版 JSON 邀请码": "Paste a BridgeDrop link or legacy JSON invitation", "邀请码文本": "Invitation text",
        "确认后会在本机保存此配对，并尝试连接该设备。当前尚未导入，也未验证设备在线。": "Confirming saves this pairing on this device and attempts to connect. It has not yet been imported or verified online.",
        "导入后，对方持有的密钥可用于与你的设备建立连接。请确认邀请码来自你信任的设备。": "The other device's key can be used to connect to this device after import. Verify that the invitation comes from a trusted device.",
        "我确认这是我信任的设备，且邀请码未公开外发": "I trust this device and confirm the invitation has not been publicly shared", "确认导入并配对": "Confirm import and pair",
        "本机名称": "Device name", "例如：我的 MacBook": "For example: My MacBook", "IP 地址，例如 192.168.1.8": "IP address, e.g. 192.168.1.8", "端口": "Port", "按地址连接": "Connect by address", "手动连接": "Manual connection",
        "自动发现失败时，输入另一台设备的局域网 IP。两台设备仍需完成配对。": "If discovery fails, enter the other device's LAN IP address. Both devices must still be paired.",
        "HTTPS 服务地址": "HTTPS server address", "中继访问令牌": "Relay access token", "保存设置": "Save settings", "跨网络中继（可选）": "Cross-network relay (optional)",
        "不同网络传输需要你部署或指定可访问的中继服务，并在两台设备上配置相同地址和令牌。文件与文字的内容在设备端加密。": "Transfers across networks require an accessible relay you deploy or choose, with the same address and token configured on both devices. File and text contents are encrypted on the devices.",
        "移除配对": "Remove pairing", "移除配对会生成新密钥，使旧邀请码及旧配对失效。已收到的文件保留，两台设备需要重新配对。": "Removing pairing generates a new key and invalidates old invitations and pairings. Received files remain; both devices must pair again.",
        "移除当前设备配对？": "Remove the current pairing?", "此操作会移除连接凭据。重新配对后才能继续传输。": "This removes the connection credentials. Pair again to resume transfers.",
        "准备连接": "Ready to connect", "已送达": "Delivered", "可继续": "Ready to resume", "应用已重新打开，点击继续从断点传输。": "The app reopened. Select Resume to continue from the saved offset.",
        "初始化失败": "Initialization failed", "传输已暂停，开启连接后可继续。": "Transfer paused. Enable the connection to resume.", "传输已暂停，返回应用后点击继续。": "Transfer paused. Return to the app and select Resume.", "接收已暂停，重新打开应用后继续": "Receiving paused; reopen the app to continue",
        "无法生成邀请，请检查本机配对配置。": "Could not create an invitation. Check this device's pairing settings.", "设备名称请填写 1 到 100 个字符。": "Enter a device name of 1 to 100 characters.",
        "设置已保存，使用局域网连接": "Settings saved; using LAN", "设置已保存，正在连接互联网服务": "Settings saved; connecting to relay", "请输入有效设备地址和端口。": "Enter a valid device address and port.",
        "无法连接该设备。请检查地址、两端配对信息、本地网络权限，并保持对方应用打开。": "Could not connect. Check the address, pairing on both devices and local-network permissions, and keep the other app open.",
        "请先扫描或导入对方的邀请码，再使用手动地址连接。": "Scan or import the other device's invitation before connecting by address.", "已配对设备": "Paired device", "已配对 · 连接可用": "Paired · available", "局域网直连": "Direct LAN connection",
        "互联网连接暂不可用，局域网仍可使用": "Relay temporarily unavailable; LAN remains available", "接收请求无效，请重新发送。": "Invalid receive request. Please send again.", "互联网接收等待恢复连接": "Waiting for relay connection to recover",
        "互联网连接": "Relay connection", "局域网直连 · 互联网备用": "Direct LAN · relay available", "请先选择已配对设备。": "Select a paired device first.", "文本请保持在 1 MiB 以内。": "Text must be between 1 byte and 1 MiB.",
        "准备发送": "Preparing to send", "每次最多选择 20 个文件。文件夹请先压缩为 ZIP。": "Select up to 20 files at a time. Compress folders to ZIP first.", "准备文件": "Preparing file",
        "请选择不超过 10 GiB 的普通文件；文件夹请先压缩。": "Choose a regular file no larger than 10 GiB. Compress folders first.", "暂存文件大小无效。": "The staged file size is invalid.", "准备失败": "Preparation failed",
        "接收已暂停，请开启连接后继续。": "Receiving is paused. Enable the connection to resume.", "发送失败": "Send failed", "配对已更换，请重新选择文件发送。": "The pairing changed. Choose the file again to send it.",
        "排队等待": "Queued", "需重新发送": "Send again", "传输已暂停。": "Transfer paused.", "等待对方接收": "Waiting for approval", "正在传输": "Transferring", "等待恢复连接": "Reconnecting", "等待校验与保存": "Verifying and saving",
        "文本已复制，可粘贴到其他应用": "Text copied; you can paste it into another app", "请用分享按钮导出，或在“文件 → 我的 iPhone → 轻传”中查找。": "Use Share to export, or find it in Files → On My iPhone → BridgeDrop.", "旧配对已解除，请重新扫描二维码": "Previous pairing removed; scan a new QR code",
        "邀请内容过长，请重新扫描轻传生成的二维码。": "The invitation is too long. Scan a new BridgeDrop QR code.", "不是有效的轻传配对链接，或链接参数缺失、重复、格式不正确。": "The pairing link is invalid or has missing, duplicate or malformed parameters.",
        "不支持此配对链接版本，请更新轻传或重新生成邀请。": "This pairing-link version is unsupported. Update BridgeDrop or create a new invitation.", "邀请链接的数据编码无效，请重新扫描或完整复制。": "The invitation encoding is invalid. Scan or copy it again in full.", "邀请码内容损坏或字段不完整，请重新生成邀请。": "The invitation is damaged or incomplete. Create a new one.",
        "无法生成配对密钥。": "Could not generate a pairing key.", "邀请码无效、已过期或版本不兼容。请在另一台设备重新显示配对二维码。": "The invitation is invalid, expired or incompatible. Show a new QR code on the other device.",
        "将另一台设备的邀请码二维码放入画面": "Place the other device's invitation QR code in the frame",
        "未获相机权限。请到系统设置中允许轻传使用相机，或返回后粘贴邀请码。": "Camera access was denied. Enable it in system settings or go back and paste the invitation.",
        "无法使用相机。请到系统设置中允许轻传使用相机，或返回后粘贴邀请码。": "Camera unavailable. Enable camera access in system settings or go back and paste the invitation.", "相机启动失败。可以返回后粘贴邀请码进行配对。": "Camera could not start. Go back and paste the invitation to pair.",
        "连接超时。请打开接收端应用，检查网络及本地网络权限后重试。": "Connection timed out. Open the receiving app and check the network and local-network permissions.", "连接已断开，已保存的分块可以继续传输。": "Connection closed. Saved chunks can be resumed.", "收到无效或过大的网络消息。": "Received an invalid or oversized network message.", "对方尚未连接，正在等待网络恢复。请保持两端应用打开。": "The other device is not connected. Waiting for the network; keep both apps open.",
        "局域网接收已开启": "LAN receiving is enabled", "等待本地网络权限或网络连接": "Waiting for local-network permission or a network connection",
        "互联网连接需要有效 HTTPS 地址和至少 32 位的独立服务器凭据。": "The relay requires a valid HTTPS address and a separate server credential of at least 32 characters.", "服务器凭据无效": "Invalid server credentials",
        "暂存文件缺失或大小发生变化，请重新选择文件发送。": "The staged file is missing or its size changed. Choose it again.", "接收端的保存确认与传输内容不一致，已停止传输。": "The receiver's saved-data acknowledgement does not match. Transfer stopped.", "对方尚未接受，可以稍后点击继续。": "The other device has not accepted. Select Resume later.", "对方拒绝、取消或校验失败。重新发送将再次请求接收。": "The receiver declined, cancelled or failed verification. Sending again creates a new request.",
        "传输信息无效或超过大小限制。": "Transfer information is invalid or exceeds the size limit.", "传输或设备标识无效。": "Invalid transfer or device ID.", "文件名称或保存路径不安全。": "Unsafe file name or save path.", "发送设备与原传输不一致。": "The sender does not match the original transfer.",
        "同一传输标识的内容信息发生变化。": "The metadata for this transfer ID changed.", "找不到这项传输。": "Transfer not found.", "请先在接收设备确认接收。": "Approve the transfer on the receiving device first.", "这项传输的当前状态不允许此操作。": "This operation is not allowed in the current transfer state.",
        "数据块无效或超过大小限制。": "Invalid or oversized data chunk.", "数据位置不连续，请查询接收进度后重试。": "Data offsets are not contiguous. Query receive progress and retry.", "重复发送的数据与已保存内容不同。": "Repeated data differs from the saved content.", "保存位置已有不同内容，已保留原文件。": "The destination contains different data; the original was retained.", "接收记录损坏，已停止操作以保护原文件。": "The receive ledger is damaged. Operations stopped to protect files.",
        "文件尚未接收完整，请从已保存的位置继续。": "The file is incomplete; resume from the saved position.", "保存的文件长度与发送信息不一致。": "The saved file size differs from the manifest.", "文件校验失败，已保留未完成文件。": "File verification failed; the incomplete file was retained.", "收到的文本不是有效 UTF-8，已保留原始数据。": "Received text is not valid UTF-8; the original data was retained.", "恢复的文本不是有效 UTF-8。": "Recovered text is not valid UTF-8.",
        "保存位置的文件与接收记录不同，已保留文件。": "The destination file differs from the receive record; the file was retained.", "已保存文件缺失或长度发生变化。": "The saved file is missing or its size changed.", "已保存文本校验失败。": "Saved text verification failed.",
        "配对密钥必须为 32 字节。": "The pairing key must be 32 bytes.", "加密包的设备或请求标识无效。": "Invalid device or request ID in the encrypted packet.", "加密包超过大小限制。": "The encrypted packet exceeds the size limit.", "加密包损坏或不完整。": "The encrypted packet is damaged or incomplete."
    ]
}
