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
    @Binding var runActive: Bool
    @Binding var mapReady: Bool
    var drawMode: Bool
    var eraseMode: Bool
    var onMapReady: (Coordinator) -> Void  // Change this to pass coordinator

    func makeUIView(context: Context) -> GMSMapView {
        let camera = GMSCameraPosition(latitude: 38.9072, longitude: -77.0369, zoom: 16)
        let map = GMSMapView(frame: .zero, camera: camera)
        map.isMyLocationEnabled = true
        map.settings.myLocationButton = true
        map.delegate = context.coordinator
        context.coordinator.map = map

        // Set up callback for when map is truly ready
        context.coordinator.onMapReady = {
            DispatchQueue.main.async {
                self.mapReady = true
            }
        }

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
        
        // Ensure parent captures the coordinator after the view has stabilized
        DispatchQueue.main.async {
            onMapReady(context.coordinator)
            context.coordinator.didNotifyParentCoordinator = true
        }
        return map
    }

    func updateUIView(_ map: GMSMapView, context: Context) {
        // Fallback: if map is ready but parent hasn't captured the coordinator yet, do it once
        if mapReady && !context.coordinator.didNotifyParentCoordinator {
            DispatchQueue.main.async {
                onMapReady(context.coordinator)
                context.coordinator.didNotifyParentCoordinator = true
            }
        }
        context.coordinator.setMode(draw: drawMode, erase: eraseMode)
        if !runActive {
        context.coordinator.refreshPolyline(with: route.coords)
        }
        if runActive {
            context.coordinator.enterRunMode()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(route: route) }

    // MARK: Coordinator
    final class Coordinator: NSObject, GMSMapViewDelegate {
        weak var map: GMSMapView?
        weak var overlay: MapTouchOverlay?
        var polyline: GMSPolyline!
        var path = GMSMutablePath()
        let route: RouteModel
        var onMapReady: (() -> Void)?
        var didNotifyParentCoordinator: Bool = false

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
        
        private var didEnterRunMode = false

        func enterRunMode() {
            guard !didEnterRunMode else { return }
            didEnterRunMode = true
            overlay?.mode = .none
            // Don't clear the polyline - let the progress tracker handle it
        }

        // Add this delegate method to detect when map is truly ready
        func mapViewDidFinishTileRendering(_ mapView: GMSMapView) {
            print("Map tiles finished rendering - map is now ready")
            onMapReady?()
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

private func formatTime(_ timeInterval: TimeInterval) -> String {
    let minutes = Int(timeInterval) / 60
    let seconds = Int(timeInterval) % 60
    return String(format: "%d:%02d", minutes, seconds)
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
    @State private var progressTracker: RunProgressTracker?
    @StateObject private var location = LocationService()
    @State private var runActive = false
    @State private var mapCoordinator: MapContainer.Coordinator?  // Change this
    @State private var mapReady = false
    @State private var draw = false
    @State private var erase = false
    @State private var runDistance: Double = 0.0
    @State private var routeProgress: Double = 0.0
    @State private var currentPace: Double = 0.0
    @State private var estimatedTimeToComplete: TimeInterval = 0
    @State private var elapsedTime: TimeInterval = 0
    @State private var currentSpeed: Double = 0.0
    
    var body: some View {
        VStack(spacing: 0) {
            // Map container with fixed height
            ZStack(alignment: .top) {
                MapContainer(
                    route: route,
                    runActive: $runActive,
                    mapReady: $mapReady,
                    drawMode: draw,
                    eraseMode: erase,
                    onMapReady: { coordinator in  // Update this
                        print("Map ready callback called")
                        self.mapCoordinator = coordinator
                        print("Map coordinator set: \(self.mapCoordinator != nil)")
                    }
                )
                .clipped()
                
                // Top toolbar overlay
                VStack(spacing: 10) {
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
                        
                        Button {
                            route.coords.removeAll()
                            route.totalMeters = 0
                            runActive = false
                            progressTracker?.cleanup()
                            progressTracker = nil
                            elapsedTime = 0.0
                            currentSpeed = 0.0
                            currentPace = 0.0
                            location.stop()
                        } label: { Label("Reset", systemImage: "trash") }
                            .buttonStyle(ToolbarStyle())
                        
                        Button {
                            print("Start Run button tapped!")
                            print("Route coords count: \(route.coords.count)")
                            print("Map coordinator: \(mapCoordinator != nil ? "available" : "nil")")
                            print("Map ready: \(mapReady)")
                            
                            guard !route.coords.isEmpty,
                                    let coordinator = mapCoordinator,
                                  let map = coordinator.map,
                                  mapReady else {
                                let reason = route.coords.isEmpty ? "No route drawn" :
                                mapCoordinator == nil ? "Coordinator not available" :
                                mapCoordinator?.map == nil ? "Map not available" : "Map not ready"
                                print("Start Run failed: \(reason)")
                                return
                            }
                            
                            print("Starting run with \(route.coords.count) route points")
                            self.runActive = true
                            self.runDistance = 0.0
                            self.routeProgress = 0.0
                            self.elapsedTime = 0.0
                            
                            // Start timer for elapsed time
                            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
                                if self.runActive {
                                    self.elapsedTime += 1.0
                                } else {
                                    timer.invalidate()
                                }
                            }
                            
                            // Create the tracker with the map from coordinator
                            let tracker = RunProgressTracker(routePoints: route.coords, mapView: map)
                            self.progressTracker = tracker
                            
                            // Pipe GPS updates → tracker
                            location.onUpdate = { [weak tracker] loc in
                                guard let tracker = tracker,
                                      let coord = self.mapCoordinator,
                                      let mapView = coord.map else { return }
                                let (runDist, routeProg) = tracker.updateProgress(with: loc, mapView: mapView)
                                DispatchQueue.main.async {
                                    self.runDistance = runDist
                                    self.routeProgress = routeProg
                                    
                                    // Calculate pace (minutes per kilometer)
                                    if runDist > 0 {
                                        let elapsedTime = Date().timeIntervalSince(location.startTime ?? Date())
                                        self.currentPace = (elapsedTime / 60) / (runDist / 1000) // min/km
                                        
                                        // Calculate current speed (km/h)
                                        if elapsedTime > 0 {
                                            self.currentSpeed = (runDist / 1000) / (elapsedTime / 3600) // km/h
                                        }
                                        
                                        // Estimate time to complete
                                        if routeProg > 0 {
                                            let remainingDistance = (1 - routeProg) * route.totalMeters
                                            let estimatedTime = (remainingDistance / 1000) * self.currentPace * 60 // seconds
                                            self.estimatedTimeToComplete = estimatedTime
                                        }
                                        
                                        // Auto-complete run when route is finished
                                        if routeProg >= 1.0 {
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                                self.runActive = false
                                                self.progressTracker?.cleanup()
                                                self.progressTracker = nil
                                                location.stop()
                                            }
                                        }
                                    }
                                }
                            }
                            
                            print("Calling location.start()")
                            location.start()
                            print("Location service started")
                        } label: {
                            Label("Start Run", systemImage: "figure.run")
                        }
                        .buttonStyle(ToolbarStyle())
                        .disabled(runActive || !mapReady)
                        
                        if runActive {
                            Button {
                                self.runActive = false
                                self.progressTracker?.cleanup()
                                self.progressTracker = nil
                                self.elapsedTime = 0.0
                                self.currentSpeed = 0.0
                                self.currentPace = 0.0
                                location.stop()
                            } label: {
                                Label("Stop Run", systemImage: "stop.fill")
                            }
                            .buttonStyle(ToolbarStyle(active: true))
                        }
                        
                        Spacer()
                    }
                    .padding(.horizontal).padding(.top, 12)
                    
                    Spacer() // Push toolbar to top
                }
            }
            .frame(height: runActive ? UIScreen.main.bounds.height * 0.5 : UIScreen.main.bounds.height * 0.7)
            
            // Stats panel below the map (no longer an overlay)
            if runActive {
                ScrollView {
                    VStack(spacing: 12) {
                        // Progress bar
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Route Progress")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(String(format: "%.1f%%", routeProgress * 100))
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            ProgressView(value: routeProgress)
                                .progressViewStyle(LinearProgressViewStyle(tint: .orange))
                        }
                        
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Route Distance")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.2f km", route.totalMeters/1000))
                                    .font(.headline)
                                    .foregroundColor(.blue)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Distance Run")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.2f km", runDistance/1000))
                                    .font(.headline)
                                    .foregroundColor(.green)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Remaining")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.2f km", (route.totalMeters * (1 - routeProgress))/1000))
                                    .font(.headline)
                                    .foregroundColor(.orange)
                            }
                        }
                        
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Current Pace")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.1f min/km", currentPace))
                                    .font(.headline)
                                    .foregroundColor(.purple)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Average Pace")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.1f min/km", elapsedTime > 0 ? (elapsedTime / 60) / (runDistance / 1000) : 0))
                                    .font(.headline)
                                    .foregroundColor(.brown)
                            }
                        }
                        
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("ETA")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(formatTime(estimatedTimeToComplete))
                                    .font(.headline)
                                    .foregroundColor(.red)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Current Speed")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.1f km/h", currentSpeed))
                                    .font(.headline)
                                    .foregroundColor(.teal)
                            }
                        }
                        
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Elapsed Time")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(formatTime(elapsedTime))
                                    .font(.headline)
                                    .foregroundColor(.indigo)
                            }
                            
                            Spacer()
                        }
                        
                        if routeProgress >= 1.0 {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Route Completed!")
                                    .font(.headline)
                                    .foregroundColor(.green)
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(16)
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
                .padding(.bottom)
            } else {
                // Show only route distance when not running
                VStack {
                    HStack {
                        Spacer()
                        Text(String(format: "Route: %.2f km", route.totalMeters/1000))
                            .font(.headline)
                            .padding(10)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top)
                    
                    Spacer()
                }
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
    
    // MARK: - Lightweight GPS service for run tracking
    final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
        private let manager = CLLocationManager()
        var onUpdate: ((CLLocation) -> Void)?
        var startTime: Date?
        
        override init() {
            super.init()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.activityType = .fitness
            manager.distanceFilter = 3  // meters between callbacks; more frequent for better tracking
            manager.allowsBackgroundLocationUpdates = false
        }
        
        func start() {
            let status = manager.authorizationStatus
            print("Location authorization status: \(status.rawValue)")
            
            switch status {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                print("Location access denied or restricted")
                // Could show an alert here
                return
            case .authorizedWhenInUse, .authorizedAlways:
                break
            @unknown default:
                break
            }
            
            manager.startUpdatingLocation()
            startTime = Date()
            print("Started location updates")
        }
        
        func stop() {
            manager.stopUpdatingLocation()
            startTime = nil
        }
        
        // CLLocationManagerDelegate
        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard let last = locations.last else { return }
            print("Location updated: \(last.coordinate.latitude), \(last.coordinate.longitude)")
            onUpdate?(last)
        }
        
        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            print("Location manager failed with error: \(error)")
        }
        
        func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
            print("Location authorization changed to: \(status.rawValue)")
            switch status {
            case .notDetermined:
                print("Location permission not determined")
            case .denied:
                print("Location permission denied")
            case .restricted:
                print("Location permission restricted")
            case .authorizedWhenInUse:
                print("Location permission granted (when in use)")
                manager.startUpdatingLocation()
            case .authorizedAlways:
                print("Location permission granted (always)")
                manager.startUpdatingLocation()
            @unknown default:
                print("Unknown location authorization status")
            }
        }
    }
}
