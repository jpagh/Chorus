import SwiftData

extension ModelContext {
    /// Saves, or logs the failure and rolls the context back. Returns whether
    /// the save landed.
    ///
    /// Without the rollback a failed change stays pending in the context and
    /// rides along on the next unrelated save that succeeds — a setting the user
    /// saw fail turns up later on its own. Callers that go on to act on what
    /// they inserted (select a new service, open a new space) must stop on
    /// `false`: the rollback has taken the insert back out.
    @discardableResult
    func saveOrRollBack(_ context: String) -> Bool {
        do {
            try save()
            return true
        } catch {
            AppLogger.dataStore.error("Failed to save (\(context)): \(error.localizedDescription)")
            rollback()
            return false
        }
    }
}
