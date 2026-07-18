import SwiftUI
import GRDB

/// The app's learning ledger (spec §5.4): every field the user corrected, newest first.
/// Transparency into what Offload is learning from.
struct CorrectionHistoryView: View {
    @State private var corrections: [Correction] = []

    var body: some View {
        List {
            if corrections.isEmpty {
                ContentUnavailableView(
                    "No corrections yet",
                    systemImage: "pencil.slash",
                    description: Text("When you edit a task's category, priority, or timing, the change is remembered here — it's how Offload learns your preferences.")
                )
            } else {
                ForEach(corrections) { correction in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(correction.field.capitalized)
                            .font(.Offload.data)
                            .foregroundStyle(Color.Offload.muted)
                        HStack(spacing: 8) {
                            Text(correction.modelValue ?? "—")
                                .strikethrough()
                                .foregroundStyle(Color.Offload.muted)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(Color.Offload.indigo)
                            Text(correction.userValue ?? "—")
                                .fontWeight(.medium)
                                .foregroundStyle(Color.Offload.text)
                        }
                        .font(.Offload.body)
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(Color.Offload.background)
                }
            }
        }
        .navigationTitle("Correction history")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            corrections = (try? await AppDatabase.shared.dbQueue.read { db in
                try Correction.order(Column("created_at").desc).limit(200).fetchAll(db)
            }) ?? []
        }
    }
}
