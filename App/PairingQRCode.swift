import CoreImage.CIFilterBuiltins

enum PairingQRCode {
    static func image(for link: String) -> CGImage? {
        guard !link.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
