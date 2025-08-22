import SwiftUI
import GoogleMaps
import CoreLocation

// MARK: - Route model
final class RouteModel: ObservableObject {
    @Published var coords: [CLLocationCoordinate2D] = []
    @Published var totalMeters: Double = 0

    func recalcDistance() {
        guard coords.count > 1 else { totalMeters = 0; return }
        var d: Double = 0
        for i in 1..<coords.count {
            let a = CLLocation(latitude: coords[i-1].latitude, longitude: coords[i-1].longitude)
            let b = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
            d += a.distance(from: b)
        }
        totalMeters = d
    }

    // Remove all points within a screen-space radius along the drag
    func erase(around screenPoint: CGPoint,
               projection: GMSProjection,
               radiusPx: CGFloat,
               in view: UIView)
    {
        // Nothing to erase
        guard !coords.isEmpty else { return }

        // If only one point, and it's inside the brush, clear it
        if coords.count == 1 {
            let p = projection.point(for: coords[0])
            let dx = p.x - screenPoint.x, dy = p.y - screenPoint.y
            if (dx*dx + dy*dy) <= radiusPx*radiusPx {
                coords.removeAll()
                totalMeters = 0
            }
            return
        }

        // 1) Start with all points kept
        var keep = [Bool](repeating: true, count: coords.count)

        // Helper: distance from segment AB to point P (in screen pixels)
        func segDistToPoint(_ a: CGPoint, _ b: CGPoint, _ p: CGPoint) -> CGFloat {
            let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let ap = CGPoint(x: p.x - a.x, y: p.y - a.y)
            let ab2 = ab.x*ab.x + ab.y*ab.y
            if ab2 == 0 { return hypot(ap.x, ap.y) }
            var t = (ap.x*ab.x + ap.y*ab.y) / ab2
            t = max(0, min(1, t))
            let c = CGPoint(x: a.x + t*ab.x, y: a.y + t*ab.y)
            return hypot(c.x - p.x, c.y - p.y)
        }

        // 2) Remove any vertex inside the brush
        for (i, c) in coords.enumerated() {
            let pt = projection.point(for: c)
            let dx = pt.x - screenPoint.x, dy = pt.y - screenPoint.y
            if (dx*dx + dy*dy) <= radiusPx*radiusPx {
                keep[i] = false
            }
        }

        // 3) Also remove endpoints of segments that pass through the brush
        for i in 1..<coords.count {
            let aPt = projection.point(for: coords[i-1])
            let bPt = projection.point(for: coords[i])
            if segDistToPoint(aPt, bPt, screenPoint) <= radiusPx {
                keep[i-1] = false
                keep[i]   = false
            }
        }

        // 4) Build the reduced list and update distance
        let newCoords = coords.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
        coords = newCoords
        recalcDistance()
    }

}

// MARK: - Map wrapper
struct MapContainer: UIViewRepresentable {
    @ObservedObject var route: RouteModel
    var drawMode: Bool
    var eraseMode: Bool

    func makeUIView(context: Context) -> GMSMapView {
        let camera = GMSCameraPosition(latitude: 38.9072, longitude: -77.0369, zoom: 16)
        let map = GMSMapView(frame: .zero, camera: camera)
        map.isMyLocationEnabled = true
        map.settings.myLocationButton = true
        map.delegate = context.coordinator
        context.coordinator.map = map

        // One polyline we update in-place (fast)
        let poly = GMSPolyline()
        poly.strokeWidth = 5
        poly.strokeColor = .systemBlue
        poly.map = map
        context.coordinator.polyline = poly
        context.coordinator.path = GMSMutablePath()

        // Touch overlay
        let overlay = MapTouchOverlay(frame: .zero)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: map.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: map.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: map.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: map.bottomAnchor),
        ])
        context.coordinator.overlay = overlay
        context.coordinator.bindOverlayCallbacks()

        return map
    }

    func updateUIView(_ map: GMSMapView, context: Context) {
        context.coordinator.setMode(draw: drawMode, erase: eraseMode)
        context.coordinator.refreshPolyline(with: route.coords)
    }

    func makeCoordinator() -> Coordinator { Coordinator(route: route) }

    // MARK: Coordinator
    final class Coordinator: NSObject, GMSMapViewDelegate {
        weak var map: GMSMapView?
        weak var overlay: MapTouchOverlay?
        var polyline: GMSPolyline!
        var path = GMSMutablePath()
        let route: RouteModel

        // tune these two for “ink” feel
        private let minPixelDelta: CGFloat = 4      // add point every ≥6px of finger movement
        private let eraseRadiusPx: CGFloat = 18     // “brush size” for eraser

        private var lastScreenPoint: CGPoint?

        init(route: RouteModel) { self.route = route }
        
        private func hardClearPolyline() {
            // Remove path and unmap to kill any render cache
            polyline.path = nil
            polyline.map = nil
            // Recreate a fresh polyline so future draws are clean
            polyline = GMSPolyline()
            polyline.strokeWidth = 5
            polyline.strokeColor = .systemBlue
            polyline.map = map
            path = GMSMutablePath()
        }
        
        func setMode(draw: Bool, erase: Bool) {
            // lock map gestures while drawing/erasing
            map?.settings.setAllGesturesEnabled(!(draw || erase))
            overlay?.mode = draw ? .draw : (erase ? .erase : .none)
            if !(draw || erase) { lastScreenPoint = nil }
        }

        func bindOverlayCallbacks() {
            overlay?.onDrawPoint = { [weak self] p in self?.handleDraw(at: p) }
            overlay?.onErasePoint = { [weak self] p in self?.handleErase(at: p) }
            overlay?.onStrokeEnded = { [weak self] in self?.strokeEnded() }
        }

        func refreshPolyline(with coords: [CLLocationCoordinate2D]) {
            if coords.count < 2 {
                // Model has effectively no route — hard clear the visual
                hardClearPolyline()
                return
            }
            // Normal rebuild
            path = GMSMutablePath()
            coords.forEach { path.add($0) }
            // Avoid animation artifacts/ghosts
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            polyline.path = path
            CATransaction.commit()
        }


        // MARK: Draw
        private func handleDraw(at p: CGPoint) {
            guard let map = map else { return }
            // throttle by screen-space distance for buttery drawing
            if let last = lastScreenPoint, (last.distanceSquared(to: p) < minPixelDelta*minPixelDelta) {
                return
            }
            lastScreenPoint = p
            let coord = map.projection.coordinate(for: p)
            route.coords.append(coord)
            route.recalcDistance()
            path.add(coord)
            polyline.path = path
        }

        private func strokeEnded() {
            lastScreenPoint = nil
            // Optional: simplify the path a little for nicer curves
            simplifyRoute(toleranceMeters: 2.0)
        }

        
        // MARK: Erase (Coordinator)
        private func handleErase(at p: CGPoint) {
            guard let map = map, let overlay = overlay else { return }

            route.erase(
                around: p,
                projection: map.projection,
                radiusPx: eraseRadiusPx,
                in: overlay
            )

            // One place to update the on‑screen geometry:
            refreshPolyline(with: route.coords)   // this hard‑clears when empty
        }


        // Simple Douglas–Peucker to reduce jitter
        private func simplifyRoute(toleranceMeters: Double) {
            guard route.coords.count > 2 else { return }
            route.coords = douglasPeucker(route.coords, toleranceMeters: toleranceMeters)
            // rebuild
            path = GMSMutablePath()
            route.coords.forEach { path.add($0) }
            polyline.path = path
        }
    }
}

// MARK: - Helpers
private extension CGPoint {
    func distanceSquared(to p: CGPoint) -> CGFloat {
        let dx = x - p.x, dy = y - p.y
        return dx*dx + dy*dy
    }
}

// Douglas–Peucker (geodesic-ish using CLLocation distances)
func douglasPeucker(_ points: [CLLocationCoordinate2D], toleranceMeters: Double) -> [CLLocationCoordinate2D] {
    guard points.count > 2 else { return points }
    var keep = [Bool](repeating: false, count: points.count)
    keep[0] = true; keep[points.count-1] = true

    func perpendicularDistance(_ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        // project to a line using simple planar approx over small spans (OK for meter-scale)
        let ax = a.latitude, ay = a.longitude
        let bx = b.latitude, by = b.longitude
        let px = p.latitude, py = p.longitude
        let abx = bx-ax, aby = by-ay
        let apx = px-ax, apy = py-ay
        let ab2 = abx*abx + aby*aby
        if ab2 == 0 { return CLLocation(latitude: ax, longitude: ay).distance(from: CLLocation(latitude: px, longitude: py)) }
        let t = max(0,min(1,(apx*abx+apy*aby)/ab2))
        let cx = ax + t*abx, cy = ay + t*aby
        return CLLocation(latitude: cx, longitude: cy).distance(from: CLLocation(latitude: px, longitude: py))
    }

    func dp(_ start: Int, _ end: Int) {
        if end <= start+1 { return }
        var maxDist = 0.0; var idx = start+1
        for i in (start+1)..<end {
            let d = perpendicularDistance(points[i], points[start], points[end])
            if d > maxDist { maxDist = d; idx = i }
        }
        if maxDist > toleranceMeters {
            keep[idx] = true
            dp(start, idx); dp(idx, end)
        }
    }

    dp(0, points.count-1)
    return points.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
}


// MARK: - UI
struct ContentView: View {
    @StateObject private var route = RouteModel()
    @State private var draw = false
    @State private var erase = false

    var body: some View {
        ZStack(alignment: .top) {
            MapContainer(route: route, drawMode: draw, eraseMode: erase)
                .ignoresSafeArea()

            HStack(spacing: 10) {
                Button {
                    draw.toggle(); if draw { erase = false }
                } label: { Label(draw ? "Drawing…" : "Draw", systemImage: "pencil.tip") }
                .buttonStyle(ToolbarStyle(active: draw))

                Button {
                    erase.toggle(); if erase { draw = false }
                } label: { Label("Erase", systemImage: "scissors") }
                .buttonStyle(ToolbarStyle(active: erase))

                Button {
                    if !route.coords.isEmpty {
                        _ = route.coords.popLast()
                        route.recalcDistance()
                    }
                } label: { Label("Undo", systemImage: "arrow.uturn.left") }
                .buttonStyle(ToolbarStyle())

                Spacer()
                Text(String(format: "Route: %.2f km", route.totalMeters/1000))
                    .font(.headline)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal).padding(.top, 12)
        }
    }
}


struct ToggleButton: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool
    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(ToolbarStyle(active: isOn))
    }
}

struct ToolbarStyle: ButtonStyle {
    var active: Bool = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(10)
            .background(
                active ? AnyShapeStyle(Color.blue.opacity(0.25))
                       : AnyShapeStyle(.ultraThinMaterial),
                in: RoundedRectangle(cornerRadius: 12)
            )

            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}
