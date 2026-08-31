import Testing
import Foundation
import GRDB
@testable import Offload

/// A ticked grocery item lasts the rest of the day and no longer.
struct GroceryTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    private func at(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour))!
    }

    private func key(_ day: Int) -> String {
        HabitProgress.dayKey(at(day), calendar: calendar)
    }

    @MainActor
    @Test("Items ticked on an earlier day are swept; today's and untouched ones stay")
    func sweepsOnlyEarlierDays() async throws {
        let appDB = try AppDatabase.makeInMemory()
        let store = GroceryStore(db: appDB)

        let toGet = GroceryItem(title: "Milk", sortOrder: 1)
        let ticketedToday = GroceryItem(title: "Eggs", bought: true, boughtDay: key(30), sortOrder: 2)
        let ticketedYesterday = GroceryItem(title: "Bread", bought: true, boughtDay: key(29), sortOrder: 3)
        try await appDB.dbQueue.write { db in
            for row in [toGet, ticketedToday, ticketedYesterday] { try row.insert(db) }
        }

        await store.sweepBought(now: at(30), calendar: calendar)

        let left = try await appDB.dbQueue.read { db in
            try GroceryItem.order(Column("sort_order")).fetchAll(db)
        }
        #expect(left.map(\.title) == ["Milk", "Eggs"])
    }

    @MainActor
    @Test("Nothing is swept while the day is still going")
    func keepsTickedItemsUntilDayEnd() async throws {
        let appDB = try AppDatabase.makeInMemory()
        let store = GroceryStore(db: appDB)

        // Ticked at 9am, swept at 11pm the same day — the whole point is that it survives the shop.
        let item = GroceryItem(title: "Coffee", bought: true, boughtDay: key(30), sortOrder: 1)
        try await appDB.dbQueue.write { db in try item.insert(db) }

        await store.sweepBought(now: at(30, hour: 23), calendar: calendar)

        let left = try await appDB.dbQueue.read { db in try GroceryItem.fetchCount(db) }
        #expect(left == 1)
    }

    @MainActor
    @Test("An item with no recorded day is never swept")
    func untickedItemsSurvive() async throws {
        let appDB = try AppDatabase.makeInMemory()
        let store = GroceryStore(db: appDB)

        // `bought` without a day shouldn't happen after the v12 backfill, but a sweep that deletes
        // rows it can't date would be an unrecoverable way to be wrong.
        let dateless = GroceryItem(title: "Rice", bought: true, boughtDay: nil, sortOrder: 1)
        try await appDB.dbQueue.write { db in try dateless.insert(db) }

        await store.sweepBought(now: at(31), calendar: calendar)

        let left = try await appDB.dbQueue.read { db in try GroceryItem.fetchCount(db) }
        #expect(left == 1)
    }

    @MainActor
    @Test("Ticking stamps the day, unticking clears it")
    func togglingStampsTheDay() async throws {
        let appDB = try AppDatabase.makeInMemory()
        let store = GroceryStore(db: appDB)

        let item = GroceryItem(title: "Oats", sortOrder: 1)
        try await appDB.dbQueue.write { db in try item.insert(db) }

        await store.toggle(item, now: at(30), calendar: calendar)
        var stored = try await appDB.dbQueue.read { db in try GroceryItem.fetchOne(db, key: item.id) }
        #expect(stored?.bought == true)
        #expect(stored?.boughtDay == key(30))

        // Put it back in the trolley: the stamp has to go too, or tonight's sweep takes an item
        // that's still to get.
        await store.toggle(stored!, now: at(30), calendar: calendar)
        stored = try await appDB.dbQueue.read { db in try GroceryItem.fetchOne(db, key: item.id) }
        #expect(stored?.bought == false)
        #expect(stored?.boughtDay == nil)
    }
}
