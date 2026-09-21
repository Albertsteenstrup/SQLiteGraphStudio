import SwiftUI

struct GraphFilterEditor: View {
    @Bindable var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var minimumFields: String
    @State private var maximumFields: String
    @State private var minimumRows: String
    @State private var maximumRows: String
    @State private var error: String?

    init(session: AppSession) {
        self.session = session
        let filter = session.graphTableFilter
        _minimumFields = State(initialValue: filter.minimumFields.map(String.init) ?? "")
        _maximumFields = State(initialValue: filter.maximumFields.map(String.init) ?? "")
        _minimumRows = State(initialValue: filter.minimumRows.map(String.init) ?? "")
        _maximumRows = State(initialValue: filter.maximumRows.map(String.init) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Filter tables").font(.headline)
            Text("Leave a bound empty for no limit.").font(.caption).foregroundStyle(.secondary)
            range("Fields", minimum: $minimumFields, maximum: $maximumFields)
            range("Rows", minimum: $minimumRows, maximum: $maximumRows)
            if let progress = session.graphFilterProgress {
                ProgressView("Counting rows… \(progress) tables checked")
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Reset") {
                    session.clearGraphFilter()
                    dismiss()
                }
                Spacer()
                Button("Cancel") { session.cancelGraphFilter(); dismiss() }
                Button("Apply") {
                    do {
                        let filter = GraphTableFilter(
                            minimumFields: try bound(minimumFields), maximumFields: try bound(maximumFields),
                            minimumRows: try bound(minimumRows), maximumRows: try bound(maximumRows)
                        )
                        guard filter.isValid else { error = "The minimum cannot exceed the maximum."; return }
                        error = nil
                        Task { if await session.applyGraphFilter(filter) { dismiss() } }
                    } catch { self.error = "Enter whole numbers greater than or equal to zero." }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(session.graphFilterProgress != nil)
            }
        }
        .padding(18)
        .frame(width: 370)
    }

    private func range(_ title: String, minimum: Binding<String>, maximum: Binding<String>) -> some View {
        HStack {
            Text(title).frame(width: 50, alignment: .leading)
            TextField("Minimum", text: minimum).accessibilityLabel("Minimum \(title.lowercased())")
            Text("to").foregroundStyle(.secondary)
            TextField("Maximum", text: maximum).accessibilityLabel("Maximum \(title.lowercased())")
        }.textFieldStyle(.roundedBorder)
    }

    private func bound(_ text: String) throws -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        guard let value = Int(text), value >= 0 else { throw CocoaError(.formatting) }
        return value
    }
}
