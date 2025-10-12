import Foundation

struct SavedSearch: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var query: String
}

enum SavedSearchStore {
    private static let defaultsKey = "aegiro.savedSearches"

    static func load() -> [SavedSearch] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        do {
            return try JSONDecoder().decode([SavedSearch].self, from: data)
        } catch {
            return []
        }
    }

    static func save(_ searches: [SavedSearch]) {
        do {
            let data = try JSONEncoder().encode(searches)
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } catch {
            // Best effort; ignore errors for now
        }
    }
}
