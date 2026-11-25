import SwiftUI

struct SpeedCurveEditor: View {
    @EnvironmentObject private var rehearsal: RehearsalSession
    @ObservedObject var controller: TrackingController
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

    let embedded: Bool

    init(controller: TrackingController, settings: AppSettings, initialSlot: Int, embedded: Bool = false) {
        self.embedded = embedded
        self.controller = controller
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
                Picker("Preset", selection: Binding(get: { selection.slot }, set: { slot in
                    selection.slot = slot
                    if embedded { rehearsal.compareMode = TrackingSpeedMode.allCases[slot + 1] }
                })) {
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
            .frame(height: embedded ? 160 : 290)

            if embedded {
                HStack {
                    axisReading("Pan", point: rehearsal.frame?.pan, color: .orange)
                    axisReading("Tilt", point: rehearsal.frame?.tilt, color: .cyan)
                    Spacer()
                    if rehearsal.analyzing { Text("Analyzing clip…") }
                    else if rehearsal.frame?.target == nil { Text("No target detected") }
                }
                .font(.caption)
            }

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
                Button("Done") { if embedded { rehearsal.editingCurves = false } else { dismiss() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(embedded ? 10 : 22)
        .frame(minWidth: 620, idealWidth: 680, maxWidth: embedded ? .infinity : 680)
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
            let replay = controller.controlPanelTab == .rehearsal
            if (replay ? rehearsal.compareMode : settings.trackingSpeedMode).slot == selection.slot {
                marker("P", point: replay ? rehearsal.frame?.pan : controller.panPoint, color: .orange, rect: rect)
                marker("T", point: replay ? rehearsal.frame?.tilt : controller.tiltPoint, color: .cyan, rect: rect)
            }
        }
        .coordinateSpace(name: "speedGraph")
    }

    private func axisReading(_ axis: String, point: SpeedCurve.Point?, color: Color) -> some View {
        Label("\(axis) · \(point.map { "\(Int(($0.y * 100).rounded()))%" } ?? "Hold")",
              systemImage: "circle.fill")
            .foregroundStyle(color)
    }

    @ViewBuilder private func marker(_ label: String, point: SpeedCurve.Point?, color: Color, rect: CGRect) -> some View {
        if let point {
            let p = position(point, in: rect)
            ZStack {
                Circle().strokeBorder(color, lineWidth: 3).frame(width: 18, height: 18)
                Text(label).font(.caption.bold()).foregroundStyle(color)
                    .padding(2).background(.black.opacity(0.8), in: Capsule())
                    .offset(x: label == "P" ? -13 : 13, y: -10)
            }
            .position(p)
            .allowsHitTesting(false)
        }
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
        let available = spans.filter { width($0) >= 0.022 }
        let index = selectedIndex.flatMap { available.contains($0) ? $0 : nil }
            ?? available.max { width($0) < width($1) }
        guard let index else { return }
        selection.node = curve.wrappedValue.split(after: index)
    }
}
