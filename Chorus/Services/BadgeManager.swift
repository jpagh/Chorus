import Foundation
import AppKit

@MainActor
@Observable
final class BadgeManager {
    /// The true, unmasked unread count per service. Always reflects what the
    /// page actually reported — muting and the per-service show-badge toggle
    /// are applied as a *display mask* (see `maskedIDs`), never by zeroing the
    /// stored count. This keeps `rawCount` meaningful for adaptive polling and
    /// lets un-muting restore the badge instantly without waiting for a poll.
    private(set) var counts: [UUID: Int] = [:]

    /// Services whose badge is hidden because they are muted or have the
    /// show-badge toggle off. Their real count still lives in `counts`.
    private var maskedIDs: Set<UUID> = []

    /// Services whose count went up while you were looking at something else,
    /// and that you have not opened since. Their count pulses in the rail until
    /// you open them or the count reaches zero.
    private(set) var attentionIDs: Set<UUID> = []

    /// The service on screen, from `AppState.selectedServiceID`. Opening a
    /// service clears its attention, and a count that goes up on screen only
    /// flashes.
    var activeServiceID: UUID? {
        didSet {
            if let activeServiceID { attentionIDs.remove(activeServiceID) }
        }
    }

    /// Whether a service's count is waiting to be seen.
    func needsAttention(_ id: UUID) -> Bool {
        attentionIDs.contains(id) && !maskedIDs.contains(id) && !doNotDisturb
    }

    /// Whether any of these services' counts is waiting to be seen.
    func needsAttention(anyOf ids: [UUID]) -> Bool {
        ids.contains(where: needsAttention)
    }

    /// Records a change of count for the attention rule: up while elsewhere
    /// asks for attention, down to zero lets it go.
    private func noteCountChange(_ id: UUID, from old: Int, to new: Int) {
        if new == 0 {
            attentionIDs.remove(id)
        } else if new > old, id != activeServiceID {
            attentionIDs.insert(id)
        }
    }

    #if DEBUG
    /// Made-up counts for looking at the badges in a Debug build, laid over
    /// the real ones so polling cannot wipe them. See `AppState.applyDebugMockBadges`.
    var mockCounts: [UUID: Int] = [:] {
        didSet { updateDockBadge() }
    }

    /// Raises one made-up count by one, so a Debug build can show a count
    /// going up and the attention pulse that follows.
    func bumpMockCount(for id: UUID) {
        let old = mockCounts[id] ?? 0
        mockCounts[id] = old + 1
        noteCountChange(id, from: old, to: old + 1)
    }
    #endif

    /// The count to show for a service: the page's, or in a Debug build a
    /// made-up one when there is one.
    private func shownCount(_ id: UUID) -> Int {
        #if DEBUG
        if let mock = mockCounts[id] { return mock }
        #endif
        return counts[id] ?? 0
    }

    var doNotDisturb: Bool = false {
        // Mirror into a thread-safe snapshot so the UNUserNotificationCenter
        // delegate can read Do Not Disturb from its callback without asserting
        // main-actor isolation (that callback isn't contractually main-thread;
        // an off-main read via MainActor.assumeIsolated would hard-crash).
        didSet { doNotDisturbSnapshot.value = doNotDisturb }
    }

    /// Off-main-safe mirror of `doNotDisturb`. See the property's didSet.
    nonisolated let doNotDisturbSnapshot = AtomicBool(false)

    var showBadgeCountInDock: Bool = true {
        didSet { updateDockBadge() }
    }

    var totalCount: Int {
        guard !doNotDisturb else { return 0 }
        #if DEBUG
        let ids = Set(counts.keys).union(mockCounts.keys)
        #else
        let ids = Set(counts.keys)
        #endif
        return ids.reduce(0) { $0 + (maskedIDs.contains($1) ? 0 : shownCount($1)) }
    }

    /// Returns the raw stored count regardless of DND or masking. Used by
    /// adaptive polling to compare deltas without any mask zeroing both sides.
    func rawCount(for instanceID: UUID) -> Int {
        counts[instanceID] ?? 0
    }

    func badgeCount(for instanceID: UUID) -> Int {
        guard !doNotDisturb, !maskedIDs.contains(instanceID) else { return 0 }
        return shownCount(instanceID)
    }

    func aggregateCount(for serviceIDs: [UUID]) -> Int {
        guard !doNotDisturb else { return 0 }
        return serviceIDs.reduce(0) { sum, id in
            sum + (maskedIDs.contains(id) ? 0 : shownCount(id))
        }
    }

    func updateBadge(for instanceID: UUID, count: Int, isMuted: Bool, showBadge: Bool = true) {
        // Clamp to a sane badge range. The DOM-badge path (catalog badgeJS) is
        // otherwise unbounded, so a page whose expression yields a negative or
        // garbage-large value would corrupt totalCount/aggregateCount — one
        // negative can zero out or hide the dock badge for every other service.
        let clamped = max(0, min(count, 999))
        noteCountChange(instanceID, from: counts[instanceID] ?? 0, to: clamped)
        // Always store the (clamped) true count; muting / show-badge only
        // toggles the display mask. Storing the real value (rather than 0) keeps
        // adaptive polling's delta detection correct for muted services and
        // makes un-muting instantaneous.
        counts[instanceID] = clamped
        if isMuted || !showBadge {
            maskedIDs.insert(instanceID)
        } else {
            maskedIDs.remove(instanceID)
        }
        updateDockBadge()
    }

    func removeBadge(for instanceID: UUID) {
        counts.removeValue(forKey: instanceID)
        attentionIDs.remove(instanceID)
        maskedIDs.remove(instanceID)
        updateDockBadge()
    }

    func updateDockBadge() {
        // Use NSApplication.shared rather than the NSApp global — the
        // global is an implicitly-unwrapped optional that can still be
        // nil during early AppState init (and in test hosts), and reading
        // .dockTile through it then traps. NSApplication.shared is lazy
        // and safe even before the run loop is up.
        let dockTile = NSApplication.shared.dockTile
        if doNotDisturb || !showBadgeCountInDock {
            dockTile.badgeLabel = nil
        } else {
            let total = totalCount
            dockTile.badgeLabel = total > 0 ? "\(total)" : nil
        }
    }
}

/// A minimal thread-safe boolean, so a value owned by a `@MainActor` type can
/// be read safely from a non-isolated context (e.g. a system delegate callback
/// that isn't guaranteed to run on the main thread).
final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool

    init(_ value: Bool) { self._value = value }

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
