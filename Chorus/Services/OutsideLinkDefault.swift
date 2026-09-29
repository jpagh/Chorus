import Foundation
import SwiftData

/// Where a link opens when it leaves a service and no other Chorus service owns
/// it: a Chorus window or the browser. One setting for every service, in
/// Settings, which each service can override in its own editor.
///
/// It lives in defaults rather than `AppPreferences` so it needs no schema
/// version, the way `ServiceNameVisibility` does. Off, the browser, is the
/// behaviour Chorus has always had.
enum OutsideLinkDefault {
    static let defaultsKey = "openOutsideLinksInChorus"

    static func opensInChorus(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    /// One-time cleanup, run at launch. Until the global setting existed, the
    /// service editor wrote its toggle on every save, so any service the user
    /// had ever edited carries a `false` they never chose. `false` was also the
    /// only default, so clearing those back to nil changes nothing today, and
    /// lets those services follow the global setting when the user changes it.
    /// A `true` was a real choice and stays.
    static let pinsClearedKey = "outsideLinkPinsCleared"

    @MainActor
    static func clearUnchosenPins(in context: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: pinsClearedKey) else { return }
        let services = (try? context.fetch(FetchDescriptor<ServiceInstance>())) ?? []
        for service in services where service.openExternalLinksInApp == false {
            service.openExternalLinksInApp = nil
        }
        if context.saveOrRollBack("clear outside-link pins") {
            defaults.set(true, forKey: pinsClearedKey)
        }
    }
}
