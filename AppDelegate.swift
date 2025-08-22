import UIKit
import GoogleMaps

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if let key = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_MAPS_API_KEY") as? String {
            GMSServices.provideAPIKey(key)
        }
        return true
    }
}
