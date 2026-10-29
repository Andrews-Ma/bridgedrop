#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

struct QRScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        ScannerViewController(onScan: onScan)
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "app.bridgedrop.camera")
    private let onScan: (String) -> Void
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didScan = false
    private var didConfigure = false
    private let message = UILabel()

    init(onScan: @escaping (String) -> Void) {
        self.onScan = onScan
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Storyboard is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer

        message.text = "将另一台设备的邀请码二维码放入画面"
        message.textColor = .white
        message.font = .preferredFont(forTextStyle: .body)
        message.textAlignment = .center
        message.numberOfLines = 0
        message.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        message.layer.cornerRadius = 14
        message.clipsToBounds = true
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)
        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            message.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            message.heightAnchor.constraint(greaterThanOrEqualToConstant: 70)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.view.window != nil else { return }
                    if granted { self.configureAndStart() }
                    else { self.showError("未获相机权限。请到系统设置中允许轻传使用相机，或返回后粘贴邀请码。") }
                }
            }
        default:
            showError("无法使用相机。请到系统设置中允许轻传使用相机，或返回后粘贴邀请码。")
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureAndStart() {
        guard !didConfigure else {
            sessionQueue.async { [session] in
                if !session.isRunning { session.startRunning() }
            }
            return
        }
        didConfigure = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let camera = AVCaptureDevice.default(for: .video) else {
                    throw ScannerError.unavailable
                }
                let input = try AVCaptureDeviceInput(device: camera)
                let output = AVCaptureMetadataOutput()
                self.session.beginConfiguration()
                self.session.sessionPreset = .high
                guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                    self.session.commitConfiguration()
                    throw ScannerError.unavailable
                }
                self.session.addInput(input)
                self.session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                self.session.commitConfiguration()
                self.session.startRunning()
            } catch {
                DispatchQueue.main.async {
                    self.showError("相机启动失败。可以返回后粘贴邀请码进行配对。")
                }
            }
        }
    }

    private func showError(_ text: String) { message.text = text }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !didScan,
              let value = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else {
            return
        }
        didScan = true
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        // Forward both app links and legacy JSON to the same review-only model entry.
        // The scanner never imports keys or starts connections.
        onScan(value)
    }

    private enum ScannerError: Error { case unavailable }
}
#endif
