import Testing
@testable import Offload

struct SearchStoreTests {

    private let sample = [
        TaskItem(title: "Buy milk and eggs", category: "Personal", priority: "low"),
        TaskItem(title: "Email the quarterly report", category: "Work", priority: "high"),
        TaskItem(title: "Book dentist appointment", category: "Health", priority: "medium")
    ]

    @Test("Empty query returns everything")
    func emptyQuery() {
        let r = SearchStore.filter(sample, query: "  ", category: nil, priority: nil)
        #expect(r.count == 3)
    }

    @Test("All query tokens must match (AND)")
    func tokenAnd() {
        #expect(SearchStore.filter(sample, query: "milk eggs", category: nil, priority: nil).count == 1)
        #expect(SearchStore.filter(sample, query: "milk report", category: nil, priority: nil).isEmpty)
        // Case-insensitive.
        #expect(SearchStore.filter(sample, query: "EMAIL", category: nil, priority: nil).count == 1)
    }

    @Test("Category and priority filters narrow results")
    func filters() {
        #expect(SearchStore.filter(sample, query: "", category: "Work", priority: nil).count == 1)
        #expect(SearchStore.filter(sample, query: "", category: nil, priority: "high").count == 1)
        #expect(SearchStore.filter(sample, query: "", category: "Work", priority: "low").isEmpty)
        // Filter + query together.
        #expect(SearchStore.filter(sample, query: "book", category: "Health", priority: nil).count == 1)
    }
}
