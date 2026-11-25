import SwiftUI

struct SpeedCurveEditor: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    private final class Selection: ObservableObject {
        @Published var slot: Int { didSet { node = nil } }
        @Published var pan = true { didSet { node = nil } }
        @Published var node: UUID?
        @Published var confirmingAxisCopy = false

        init(slot: Int) { self.slot = slot }
    }

    @StateObject private var selection: Selection

    init(settings: AppSettings, initialSlot: Int) {
        self.settings = settings
        _selection = StateObject(wrappedValue: Selection(slot: initialSlot))
    }

    private var curve: Binding<SpeedCurve> {
        selection.pan ? $settings.trackingSpeedProfiles[selection.slot].pan : $settings.trackingSpeedProfiles[selection.slot].tilt
    }

    private var selectedIndex: Int? { curve.wrappedValue.nodes.firstIndex { $0.id == selection.node } }

    private var copyTitle: String { selection.pan ? "Copy Pan to Tilt" : "Copy Tilt to Pan" }
    private var destinationAxis: String { selection.pan ? "Tilt" : "Pan" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Preset", selection: $selection.slot) {
                    ForEach(0..<3) { index in Text("Preset \(index + 1)").tag(index) }
                }
                TextField("Preset name", text: $settings.trackingSpeedProfiles[selection.slot].name)
                Picker("Axis", selection: $selection.pan) {
                    Text("Pan").tag(true)
                    Text("Tilt").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
            }

            GeometryReader { geometry in
                let rect = CGRect(x: 44, y: 16, width: geometry.size.width - 74,
                                  height: geometry.size.height - 54)
                graph(in: rect)
            }
            .frame(height: 290)

            Text("Drag nodes to set speed. Select a node to adjust each handle independently.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Add Node") { addNode() }
                    .disabled(curve.wrappedValue.nodes.count >= 32)
                Button("Remove Node") {
                    guard let selectedIndex else { return }
                    curve.wrappedValue.nodes.remove(at: selectedIndex)
                    selection.node = nil
                }
                .disabled(selectedIndex.map { curve.wrappedValue.nodes[$0].marker != nil } ?? true)

                if let selectedIndex {
                    let node = curve.wrappedValue.nodes[selectedIndex]
                    Text("\(node.marker ?? "Node") · \(Int((node.point.y * 100).rounded()))%")
                        .monospacedDigit()
                }
                Spacer()
                Button(copyTitle) { selection.confirmingAxisCopy = true }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 680)
        .alert(copyTitle + "?", isPresented: $selection.confirmingAxisCopy) {
            Button("Cancel", role: .cancel) {}
            Button(copyTitle) { copyToOtherAxis() }
        } message: {
            Text("This replaces the \(destinationAxis) curve in Preset \(selection.slot + 1).")
        }
    }

    private func graph(in rect: CGRect) -> some View {
        let value = curve.wrappedValue
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                var grid = Path()
                for level in [0.0, 0.25, 0.5, 0.75, 1.0] {
                    let y = position(.init(x: 0, y: level), in: rect).y
                    grid.move(to: CGPoint(x: rect.minX, y: y))
                    grid.addLine(to: CGPoint(x: rect.maxX, y: y))
                    context.draw(Text("\(Int(level * 100))%").font(.caption), at: CGPoint(x: rect.minX - 6, y: y),
                                 anchor: .trailing)
                }
                for node in value.nodes where node.marker != nil {
                    let x = position(node.point, in: rect).x
                    grid.move(to: CGPoint(x: x, y: rect.minY))
                    grid.addLine(to: CGPoint(x: x, y: rect.maxY))
                    context.draw(Text(node.marker ?? "").font(.caption), at: CGPoint(x: x, y: rect.maxY + 14),
                                 anchor: .top)
                }
                context.stroke(grid, with: .color(.secondary.opacity(0.28)))
                var path = Path()
                path.move(to: position(value.nodes[0].point, in: rect))
                for index in 1..<value.nodes.count {
                    path.addCurve(to: position(value.nodes[index].point, in: rect),
                                  control1: position(value.handle(at: index - 1, incoming: false), in: rect),
                                  control2: position(value.handle(at: index, incoming: true), in: rect))
                }
                context.stroke(path, with: .color(.accentColor), lineWidth: 2)
            }
            .accessibilityHidden(true)

            if let index = selectedIndex {
                if index > 0 { handle(index, incoming: true, in: rect) }
                if index + 1 < value.nodes.count { handle(index, incoming: false, in: rect) }
            }
            ForEach(Array(value.nodes.enumerated()), id: \.element.id) { index, node in
                Circle()
                    .fill(selection.node == node.id ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: 13, height: 13)
                    .position(position(node.point, in: rect))
                    .onTapGesture { selection.node = node.id }
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("speedGraph"))
                        .onChanged { gesture in
                            selection.node = node.id
                            curve.wrappedValue.moveNode(at: index, to: point(gesture.location, in: rect))
                        })
                    .accessibilityLabel("\(node.marker ?? "Curve node"), \(Int((node.point.y * 100).rounded())) percent")
            }
        }
        .coordinateSpace(name: "speedGraph")
    }

    private func handle(_ index: Int, incoming: Bool, in rect: CGRect) -> some View {
        let value = curve.wrappedValue
        let origin = position(value.nodes[index].point, in: rect)
        let end = position(value.handle(at: index, incoming: incoming), in: rect)
        return ZStack {
            Path { path in
                path.move(to: origin)
                path.addLine(to: end)
            }
            .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .allowsHitTesting(false)

            Rectangle()
                .fill(Color.secondary)
                .frame(width: 10, height: 10)
                .position(end)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("speedGraph"))
                    .onChanged { gesture in
                        curve.wrappedValue.moveHandle(at: index, incoming: incoming, to: point(gesture.location, in: rect))
                    })
                .accessibilityLabel(incoming ? "Incoming handle" : "Outgoing handle")
        }
    }

    private func position(_ point: SpeedCurve.Point, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.maxY - point.y * rect.height)
    }

    private func point(_ location: CGPoint, in rect: CGRect) -> SpeedCurve.Point {
        .init(x: min(1, max(0, (location.x - rect.minX) / rect.width)),
              y: min(1, max(0, (rect.maxY - location.y) / rect.height)))
    }

    private func copyToOtherAxis() {
        let source = curve.wrappedValue
        if selection.pan {
            settings.trackingSpeedProfiles[selection.slot].tilt = source
        } else {
            settings.trackingSpeedProfiles[selection.slot].pan = source
        }
    }

    private func addNode() {
        let value = curve.wrappedValue
        let spans = 0..<(value.nodes.count - 1)
        func width(_ index: Int) -> Double { value.nodes[index + 1].point.x - value.nodes[index].point.x }
        let available = spans.filter { width($0) >= 0.008 }
        let index = selectedIndex.flatMap { available.contains($0) ? $0 : nil }
            ?? available.max { width($0) < width($1) }
        guard let index else { return }
        let x = value.nodes[index].point.x + width(index) / 2
        let y = value.speed(at: x)
        let node = SpeedCurve.Node(point: .init(x: x, y: y),
                                   incoming: .init(x: 0.25, y: y), outgoing: .init(x: 0.25, y: y))
        curve.wrappedValue.nodes.insert(node, at: index + 1)
        selection.node = node.id
    }
}
