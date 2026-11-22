import AVFoundation
import SwiftUI

struct VideoPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
    }

    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            previewLayer.backgroundColor = NSColor.black.cgColor
            layer = previewLayer
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}

struct TrackingOverlayView: View {
    let target: TrackedTarget?
    let bufferZone: Double
    let motion: PTZMotion
    let trackingEnabled: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dead-zone rectangle
                let insetX = geo.size.width * bufferZone
                let insetY = geo.size.height * bufferZone
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .frame(
                        width: max(0, geo.size.width - insetX * 2),
                        height: max(0, geo.size.height - insetY * 2)
                    )
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)

                // Crosshair
                Path { path in
                    path.move(to: CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.42))
                    path.addLine(to: CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.58))
                    path.move(to: CGPoint(x: geo.size.width * 0.46, y: geo.size.height / 2))
                    path.addLine(to: CGPoint(x: geo.size.width * 0.54, y: geo.size.height / 2))
                }
                .stroke(Color.white.opacity(0.45), lineWidth: 1)

                if let target {
                    let rect = visionRectToView(target.boundingBox, in: geo.size)
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(trackingEnabled ? Color(red: 1.0, green: 0.72, blue: 0.2) : Color.cyan.opacity(0.85), lineWidth: 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill((trackingEnabled ? Color.orange : Color.cyan).opacity(0.12))
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)

                    Circle()
                        .fill(trackingEnabled ? Color.orange : Color.cyan)
                        .frame(width: 8, height: 8)
                        .position(x: rect.midX, y: rect.midY)

                    Text("\(Int(target.confidence * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .position(x: rect.midX, y: max(14, rect.minY - 12))
                }

                VStack {
                    HStack {
                        statusChip
                        Spacer()
                        motionChip
                    }
                    .padding(12)
                    Spacer()
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var statusChip: some View {
        Text(trackingEnabled ? "TRACKING" : "ARMED OFF")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(trackingEnabled ? Color.black : Color.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                (trackingEnabled ? Color(red: 1.0, green: 0.72, blue: 0.2) : Color.white.opacity(0.18)),
                in: RoundedRectangle(cornerRadius: 4)
            )
    }

    private var motionChip: some View {
        Text(motionLabel)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
    }

    private var motionLabel: String {
        switch motion {
        case .idle:
            return "HOLD"
        case let .moving(pan, tilt, panSpeed, tiltSpeed):
            var parts: [String] = []
            switch pan {
            case .left: parts.append("PAN L \(panSpeed)")
            case .right: parts.append("PAN R \(panSpeed)")
            case .stop: break
            }
            switch tilt {
            case .up: parts.append("TILT U \(tiltSpeed)")
            case .down: parts.append("TILT D \(tiltSpeed)")
            case .stop: break
            }
            return parts.isEmpty ? "HOLD" : parts.joined(separator: " · ")
        }
    }

    /// Convert Vision normalized rect (origin bottom-left) to view coords (origin top-left).
    private func visionRectToView(_ box: CGRect, in size: CGSize) -> CGRect {
        let x = box.origin.x * size.width
        let w = box.width * size.width
        let h = box.height * size.height
        let y = (1.0 - box.origin.y - box.height) * size.height
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
