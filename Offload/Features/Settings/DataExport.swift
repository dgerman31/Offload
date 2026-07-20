import Foundation
import GRDB
import SwiftUI
import UniformTypeIdentifiers

/// Export everything as JSON.
///
/// The whole premise is that your data lives on your device and nowhere else — which is only
/// genuinely reassuring if you can get it *out*. No lock-in, no "export to our cloud": one
/// readable file you own, that outlives this app.
enum DataExport {

    /// A snapshot of the database in a plain, self-describing shape.
    struct Archive: Codable, Sendable {
        var exportedAt: String
        var appVersion: String
        var tasks: [TaskItem]
        var projects: [Project]
        var captures: [Capture]

        var summary: String {
            "\(tasks.count) task\(tasks.count == 1 ? "" : "s") · \(projects.count) project\(projects.count == 1 ? "" : "s") · \(captures.count) capture\(captures.count == 1 ? "" : "s")"
        }
    }

    static func build(db: AppDatabase = .shared) async throws -> Archive {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return try await db.dbQueue.read { database in
            Archive(
                exportedAt: ISO8601DateFormatter().string(from: Date()),
                appVersion: version,
                tasks: try TaskItem.fetchAll(database),
                projects: try Project.fetchAll(database),
                captures: try Capture.fetchAll(database)
            )
        }
    }

    /// Pretty-printed with sorted keys so diffs between two exports are actually readable.
    static func encode(_ archive: Archive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(archive)
    }

    static func filename(now: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return "Offload-\(df.string(from: now)).json"
    }

    /// Write to a temporary file for the share sheet.
    static func writeTemporaryFile(_ data: Data, now: Date = Date()) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename(now: now))
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// Settings row that builds the archive and hands it to the share sheet.
struct ExportDataButton: View {
    @State private var exporting = false
    @State private var exportURL: URL?
    @State private var summary: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await export() }
            } label: {
                HStack {
                    Label("Export everything", systemImage: "square.and.arrow.up")
                    if exporting { Spacer(); ProgressView() }
                }
            }
            .disabled(exporting)

            if let summary {
                Text(summary)
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
            }
            if failed {
                Text("Couldn't build the export. Try again.")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.amber)
            }
        }
        .sheet(item: $exportURL) { url in
            ShareSheet(items: [url])
        }
    }

    private func export() async {
        exporting = true
        failed = false
        do {
            let archive = try await DataExport.build()
            let data = try DataExport.encode(archive)
            exportURL = try DataExport.writeTemporaryFile(data)
            summary = archive.summary
        } catch {
            failed = true
        }
        exporting = false
    }
}

/// `URL` isn't `Identifiable`; this makes `.sheet(item:)` usable without a wrapper type.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Minimal UIKit share sheet bridge.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
