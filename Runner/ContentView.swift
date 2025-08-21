import SwiftUI
import GoogleMaps

struct MapView: UIViewRepresentable {
    func makeUIView(context: Context) -> GMSMapView {
        let camera = GMSCameraPosition(latitude: 38.9072,
                                       longitude: -77.0369,
                                       zoom: 14) // DC center

        // Use default mapID (null identifier)
        let mapView = GMSMapView(frame: .zero, camera: camera)

        return mapView
    }

    func updateUIView(_ uiView: GMSMapView, context: Context) {}
}

struct ContentView: View {
    var body: some View {
        MapView()
            .ignoresSafeArea()
    }
}
