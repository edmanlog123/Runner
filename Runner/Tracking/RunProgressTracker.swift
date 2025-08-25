import CoreLocation
import GoogleMaps

class RunProgressTracker {
    private var routePoints: [CLLocationCoordinate2D] = []
    private var cumulativeDistances: [Double] = []  // meters
    
    private var completedPolyline: GMSPolyline?
    private var remainingPolyline: GMSPolyline?
    private var runnerMarker: GMSMarker?
    
    // Track actual runner movement
    private var lastLocation: CLLocation?
    private var totalDistanceRun: Double = 0.0
    
    init(routePoints: [CLLocationCoordinate2D], mapView: GMSMapView) {
        print("RunProgressTracker initializing with \(routePoints.count) route points")
        self.routePoints = routePoints
        self.cumulativeDistances = RunProgressTracker.precomputeDistances(points: routePoints)
        
        // Create runner marker
        let marker = GMSMarker()
        marker.title = "Runner"
        marker.snippet = "Your current position"
        marker.icon = GMSMarker.markerImage(with: .systemGreen)
        marker.map = mapView
        self.runnerMarker = marker
        
        // Only draw route if we have points
        if routePoints.count > 1 {
            // Draw initial "remaining" route in blue
            let path = GMSMutablePath()
            routePoints.forEach { path.add($0) }
            let polyline = GMSPolyline(path: path)
            polyline.strokeColor = .systemBlue
            polyline.strokeWidth = 5.0
            polyline.map = mapView
            self.remainingPolyline = polyline
            print("Initial route polyline created")
        } else {
            print("Warning: Not enough route points to create polyline")
        }
    }
    
    /// Precompute cumulative distances for faster lookup
    private static func precomputeDistances(points: [CLLocationCoordinate2D]) -> [Double] {
        guard points.count > 1 else { return [0] }
        var distances: [Double] = [0.0]
        var total: Double = 0.0
        for i in 1..<points.count {
            let d = CLLocation(latitude: points[i-1].latitude, longitude: points[i-1].longitude)
                .distance(from: CLLocation(latitude: points[i].latitude, longitude: points[i].longitude))
            total += d
            distances.append(total)
        }
        return distances
    }
    
    /// Call this from your CLLocationManagerDelegate on every GPS update
    func updateProgress(with location: CLLocation, mapView: GMSMapView) -> (Double, Double) {
        guard routePoints.count > 1 else { 
            print("No route points available for progress tracking")
            return (0.0, 0.0) 
        }
        
        // Track actual distance run
        if let lastLoc = lastLocation {
            let distance = location.distance(from: lastLoc)
            if distance > 0 && distance < 100 { // Filter out unrealistic jumps (>100m)
                totalDistanceRun += distance
            }
        }
        lastLocation = location
        
        // Find nearest segment [Pi, Pi+1]
        var nearestIndex = 0
        var nearestDist = Double.greatestFiniteMagnitude
        var projFraction: Double = 0.0
        
        for i in 0..<(routePoints.count - 1) {
            let (dist, frac) = RunProgressTracker.distanceToSegment(
                location: location.coordinate,
                p1: routePoints[i],
                p2: routePoints[i+1]
            )
            if dist < nearestDist {
                nearestDist = dist
                nearestIndex = i
                projFraction = frac
            }
        }
        
        // Distance covered along route
        let segmentLength = CLLocation(latitude: routePoints[nearestIndex].latitude,
                                       longitude: routePoints[nearestIndex].longitude)
            .distance(from: CLLocation(latitude: routePoints[nearestIndex+1].latitude,
                                       longitude: routePoints[nearestIndex+1].longitude))
        
        let coveredDistance = cumulativeDistances[nearestIndex] + projFraction * segmentLength
        
        // Calculate progress as fraction of total route
        let totalRouteDistance = cumulativeDistances.last ?? 0
        let progress = totalRouteDistance > 0 ? coveredDistance / totalRouteDistance : 0.0
        
        // Split paths
        let completedPath = GMSMutablePath()
        for i in 0...nearestIndex { completedPath.add(routePoints[i]) }
        // Add projection point
        let projection = RunProgressTracker.interpolate(
            p1: routePoints[nearestIndex],
            p2: routePoints[nearestIndex+1],
            fraction: projFraction
        )
        completedPath.add(projection)
        
        let remainingPath = GMSMutablePath()
        remainingPath.add(projection)
        for i in (nearestIndex+1)..<routePoints.count { remainingPath.add(routePoints[i]) }
        
        // Update polylines
        completedPolyline?.map = nil
        remainingPolyline?.map = nil
        
        let comp = GMSPolyline(path: completedPath)
        comp.strokeColor = .systemGreen
        comp.strokeWidth = 8.0
        comp.map = mapView
        self.completedPolyline = comp
        
        let rem = GMSPolyline(path: remainingPath)
        rem.strokeColor = .systemBlue
        rem.strokeWidth = 5.0
        rem.map = mapView
        self.remainingPolyline = rem
        
        // Update runner marker position
        runnerMarker?.position = location.coordinate
        
        print("Progress: \(coveredDistance) / \(totalRouteDistance) meters (\(progress * 100)%)")
        print("Actual distance run: \(totalDistanceRun) meters")
        
        return (totalDistanceRun, progress)
    }
    
    /// Clean up all map elements
    func cleanup() {
        completedPolyline?.map = nil
        remainingPolyline?.map = nil
        runnerMarker?.map = nil
    }
    
    /// Distance from point to segment, plus fraction along segment
    private static func distanceToSegment(location: CLLocationCoordinate2D,
                                          p1: CLLocationCoordinate2D,
                                          p2: CLLocationCoordinate2D) -> (Double, Double) {
        let A = CGPoint(x: p1.latitude, y: p1.longitude)
        let B = CGPoint(x: p2.latitude, y: p2.longitude)
        let P = CGPoint(x: location.latitude, y: location.longitude)
        
        let AB = CGPoint(x: B.x - A.x, y: B.y - A.y)
        let AP = CGPoint(x: P.x - A.x, y: P.y - A.y)
        
        let ab2 = AB.x*AB.x + AB.y*AB.y
        var frac = (AP.x*AB.x + AP.y*AB.y) / ab2
        frac = max(0.0, min(1.0, frac))  // clamp 0–1
        
        let proj = CGPoint(x: A.x + frac*AB.x, y: A.y + frac*AB.y)
        let dist = hypot(P.x - proj.x, P.y - proj.y)
        
        return (dist, frac)
    }
    
    private static func interpolate(p1: CLLocationCoordinate2D,
                                    p2: CLLocationCoordinate2D,
                                    fraction: Double) -> CLLocationCoordinate2D {
        let lat = p1.latitude + (p2.latitude - p1.latitude) * fraction
        let lng = p1.longitude + (p2.longitude - p1.longitude) * fraction
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}
