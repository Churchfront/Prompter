import Foundation
import Observation

/// Reader preferences, saved to UserDefaults whenever they change.
@MainActor
@Observable
final class SettingsStore {
    var settings: ReaderSettings {
        didSet { if settings != oldValue { persist() } }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "readerSettings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(ReaderSettings.self, from: data) {
            settings = decoded
        } else {
            settings = ReaderSettings()
        }
    }

    func resetToDefaults() {
        settings = ReaderSettings()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
