import Foundation
import Security
import UserNotifications
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

// MARK: Keychain

/// Topic names and tokens are secrets (anyone who has them can arm/disarm the tag),
/// so they live in the Keychain, not UserDefaults.
enum SecureStore {
    private static let service = "com.campusguard.app.tag"

    static func read(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func write(_ data: Data?, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard let data else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        read(key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func save<T: Encodable>(_ value: T?, _ key: String) {
        write(value.flatMap { try? JSONEncoder().encode($0) }, for: key)
    }
}

// MARK: Notifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()
    private(set) var authorized = false

    func activate() {
        center.delegate = self
        Task { await refreshStatus() }
    }

    func refreshStatus() async {
        let settings = await center.notificationSettings()
        authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func needsPrompt() async -> Bool {
        await center.notificationSettings().authorizationStatus == .notDetermined
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshStatus()
        return granted
    }

    enum Kind: String { case alarm, lost, info }

    func post(_ title: String, _ body: String, kind: Kind, id: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = "campus-guard-tag"
        content.categoryIdentifier = kind.rawValue
        switch kind {
        case .alarm:
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1
        case .lost:
            content.sound = .default
            content.interruptionLevel = .active
        case .info:
            content.interruptionLevel = .passive
        }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func clearAlarms() {
        center.removeAllDeliveredNotifications()
    }

    // Show banners even while the app is open (the red screen opens too).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

// MARK: Location (the PHONE's position; the tag has no GPS)

@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    private let manager = CLLocationManager()
    private var lastFix: (location: CLLocation, at: Date)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var authorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways: return true
        #if os(iOS)
        case .authorizedWhenInUse: return true
        #endif
        default: return false
        }
    }

    var needsPrompt: Bool { manager.authorizationStatus == .notDetermined }

    func requestAuthorization() {
        #if os(iOS)
        manager.requestWhenInUseAuthorization()
        #else
        manager.requestAlwaysAuthorization()
        #endif
    }

    /// One fresh fix (cached 30 s), or nil after `timeout`.
    func currentLocation(timeout: Duration = .seconds(8)) async -> CLLocation? {
        if let lastFix, Date().timeIntervalSince(lastFix.at) < 30 { return lastFix.location }
        guard authorized else { return nil }
        let fix: CLLocation? = await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let loc = update.location, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 200 {
                            return loc
                        }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let fix { lastFix = (fix, Date()) }
        return fix
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {}
}

// MARK: Haptics

@MainActor
enum Haptics {
    static func alarm() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }

    static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func warning() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }

    static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}
