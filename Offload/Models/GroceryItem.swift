import Foundation
import GRDB

/// One line on the grocery list.
///
/// Its own table rather than a `TaskItem` in a "Groceries" project, on purpose: forty items of
/// shopping would flood Home, get planned into the day, and each become its own overdue thing.
/// A shopping list wants to be a list — added to fast, ticked off in the aisle, and emptied.
struct GroceryItem: Codable, Identifiable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    var id: String
    var title: String
    var bought: Bool
    var sortOrder: Double
    var createdAt: String

    static let databaseTableName = "grocery_items"

    enum CodingKeys: String, CodingKey {
        case id, title, bought
        case sortOrder = "sort_order"
        case createdAt = "created_at"
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        bought: Bool = false,
        sortOrder: Double = 0,
        createdAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id
        self.title = title
        self.bought = bought
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}
