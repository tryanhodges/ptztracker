import Foundation

enum TrackingSpeedMode: String, CaseIterable, Identifiable {
    case basic, preset1 = "1", preset2 = "2", preset3 = "3"

    var id: Self { self }
    var slot: Int? { Int(rawValue).map { $0 - 1 } }
    var title: String { slot.map { "Preset \($0 + 1)" } ?? "Basic" }
}

struct SpeedCurve: Codable, Equatable {
    struct Point: Codable, Equatable {
        var x: Double
        var y: Double
    }

    struct Node: Codable, Identifiable, Equatable {
        var id = UUID()
        var point: Point
        var marker: String?
        var incoming = Point(x: 0.25, y: 0)
        var outgoing = Point(x: 0.25, y: 0)
    }

    private static let markers = ["Box Exit", "Picture Edge", "Box Re-entry", "Halfway", "Centered"]

    var nodes: [Node]

    var isValid: Bool {
        guard (5...32).contains(nodes.count),
              Set(nodes.map(\.id)).count == nodes.count,
              zip(nodes, nodes.dropFirst()).allSatisfy({ $1.point.x - $0.point.x >= 0.0039 }) else {
            return false
        }
        let anchors = nodes.filter { $0.marker != nil }
        return anchors.map(\.marker) == Self.markers.map(Optional.some)
            && anchors.map(\.point.x) == [0, 0.25, 0.5, 0.75, 1]
            && nodes.allSatisfy {
                (0...1).contains($0.point.x) && (0...1).contains($0.point.y)
                    && (0...0.5).contains($0.incoming.x) && (0...0.5).contains($0.outgoing.x)
                    && (0...1).contains($0.incoming.y) && (0...1).contains($0.outgoing.y)
            }
    }

    static func standard(pan: Bool) -> Self {
        let speeds = pan ? [0.32, 0.85, 0.46, 0.26, 0] : [0.28, 0.72, 0.4, 0.22, 0]
        return Self(nodes: speeds.enumerated().map { index, speed in
            Node(point: Point(x: Double(index) / 4, y: speed), marker: markers[index],
                 incoming: Point(x: 0.25, y: speed), outgoing: Point(x: 0.25, y: speed))
        })
    }

    // Handles use a fraction of the adjoining span and an absolute speed.
    // Each can extend at most halfway, keeping Bézier time monotonic.
    func handle(at index: Int, incoming: Bool) -> Point {
        let node = nodes[index]
        let span = nodes[index + (incoming ? -1 : 1)].point.x - node.point.x
        let handle = incoming ? node.incoming : node.outgoing
        return Point(x: node.point.x + span * handle.x, y: handle.y)
    }

    mutating func moveHandle(at index: Int, incoming: Bool, to point: Point) {
        let anchor = nodes[index].point
        let span = nodes[index + (incoming ? -1 : 1)].point.x - anchor.x
        let value = Point(x: min(0.5, max(0.04, (point.x - anchor.x) / span)), y: point.y)
        if incoming { nodes[index].incoming = value } else { nodes[index].outgoing = value }
    }

    mutating func moveNode(at index: Int, to point: Point) {
        let node = nodes[index]
        if node.marker == nil {
            nodes[index].point.x = min(nodes[index + 1].point.x - 0.004,
                                      max(nodes[index - 1].point.x + 0.004, point.x))
        }
        let delta = point.y - node.point.y
        nodes[index].point.y = point.y
        nodes[index].incoming.y = min(1, max(0, node.incoming.y + delta))
        nodes[index].outgoing.y = min(1, max(0, node.outgoing.y + delta))
    }

    func speed(at x: Double) -> Double {
        guard x > 0 else { return nodes[0].point.y }
        guard let right = nodes.firstIndex(where: { $0.point.x >= x }) else {
            return nodes[nodes.count - 1].point.y
        }
        if nodes[right].point.x == x { return nodes[right].point.y }
        let a = nodes[right - 1].point
        let b = handle(at: right - 1, incoming: false)
        let c = handle(at: right, incoming: true)
        let d = nodes[right].point
        var low = 0.0
        var high = 1.0
        for _ in 0..<16 {
            let t = (low + high) / 2
            if Self.bezier(a.x, b.x, c.x, d.x, t) < x { low = t } else { high = t }
        }
        return Self.bezier(a.y, b.y, c.y, d.y, (low + high) / 2)
    }

    private static func bezier(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ t: Double) -> Double {
        let u = 1 - t
        return u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d
    }
}

struct TrackingSpeedProfile: Codable, Equatable {
    var name: String
    var pan = SpeedCurve.standard(pan: true)
    var tilt = SpeedCurve.standard(pan: false)
}

struct CurveAxisTracking {
    private var direction = 0.0
    private var previousDistance: Double?
    private var returning = false
    private var returnBlend = 0.0
    private var lastSpeed = 0.0
    private var reentryOffset = 0.0

    mutating func command(error: Double, anchor: Double, halfBox: Double, drift: Double,
                          elapsed: Double, curve: SpeedCurve) -> Double {
        let distance = abs(error)
        let side = error < 0 ? -1.0 : 1.0
        if direction == 0 || direction != side && distance >= halfBox {
            guard distance >= halfBox else { return 0 }
            self = Self()
            direction = side
        }

        let step = max(0, elapsed)
        if direction != side || distance <= 0.002 {
            // Ease through the crosshair. Release the axis once this correction settles.
            lastSpeed = max(0, lastSpeed - 1.8 * step)
            let command = direction * lastSpeed
            if lastSpeed < 0.02 { self = Self(); return 0 }
            return command
        }

        let isOutside = distance >= halfBox
        let speed: Double
        if isOutside {
            if drift * direction < -0.025 { returning = true }
            if drift * direction > 0.025 { returning = false }
            let blendStep = step / 0.22
            returnBlend = returning ? min(1, returnBlend + blendStep) : max(0, returnBlend - blendStep)
            let pictureEdge = side > 0 ? 1 - anchor : anchor
            let fraction = min(1, max(0, (distance - halfBox) / max(0.001, pictureEdge - halfBox)))
            let outbound = curve.speed(at: 0.25 * fraction)
            let inbound = curve.speed(at: 0.5 - 0.25 * fraction)
            speed = outbound + (inbound - outbound) * returnBlend
            reentryOffset = 0
        } else {
            let progress = 1 - distance / halfBox
            let desired = curve.speed(at: 0.5 + 0.5 * progress)
            if let previousDistance, previousDistance >= halfBox {
                reentryOffset = lastSpeed - desired
            }
            speed = min(1, max(0, desired + reentryOffset))
            reentryOffset *= exp(-step / 0.12)
        }
        previousDistance = distance
        lastSpeed = speed
        return direction * speed
    }
}
