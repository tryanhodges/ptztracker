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

struct DeckLinkPreviewView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

struct TrackingOverlayView: View {
    let target: TrackedTarget?
    let candidates: [TrackedTarget]
    let deadZoneWidth: Double
    let deadZoneHeight: Double
    let framingPoint: CGPoint
    let motion: PTZMotion
    let trackingEnabled: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                let center = CGPoint(x: framingPoint.x * geo.size.width, y: framingPoint.y * geo.size.height)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    .frame(width: geo.size.width * deadZoneWidth, height: geo.size.height * deadZoneHeight)
                    .position(center)

                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black, radius: 2)
                    .position(center)

                ForEach(candidates.indices, id: \.self) { index in
                    let rect = visionRectToView(candidates[index].boundingBox, in: geo.size)
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.cyan, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }

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
        .clipped()
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

struct IgnoreZoneEditor: View {
    let zones: [IgnoreZone]
    let addZone: (CGRect) -> Void
    @GestureState private var draft: DragGesture.Value?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(Array(zones.enumerated()), id: \.element.id) { index, zone in
                    zoneOverlay(zone.rect, in: size, number: index + 1)
                }
                if let draft {
                    zoneOverlay(normalizedRect(for: draft, in: size), in: size)
                }
            }
            .contentShape(Rectangle())
            .clipped()
            .gesture(
                DragGesture(minimumDistance: 4)
                    .updating($draft) { value, draft, _ in draft = value }
                    .onEnded { value in
                        let rect = normalizedRect(for: value, in: size)
                        guard rect.width >= 0.01, rect.height >= 0.01 else { return }
                        addZone(rect)
                    }
            )
        }
        .accessibilityHidden(true)
    }

    private func normalizedRect(for drag: DragGesture.Value, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        func normalize(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(1, max(0, point.x / size.width)),
                    y: 1 - min(1, max(0, point.y / size.height)))
        }
        let start = normalize(drag.startLocation)
        let end = normalize(drag.location)
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                      width: abs(start.x - end.x), height: abs(start.y - end.y))
    }

    private func zoneOverlay(_ rect: CGRect, in size: CGSize, number: Int? = nil) -> some View {
        Rectangle()
            .fill(Color.red.opacity(0.24))
            .overlay {
                Rectangle().strokeBorder(.red.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
            .overlay(alignment: .topLeading) {
                if let number {
                    Text("Zone \(number)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.65))
                }
            }
            .frame(width: rect.width * size.width, height: rect.height * size.height)
            .position(x: rect.midX * size.width, y: (1 - rect.midY) * size.height)
            .allowsHitTesting(false)
    }
}
