import SwiftUI

struct TableFilterEditor: View {
    let tab: TableTabModel
    @State private var columnName = ""
    @State private var comparison: ColumnFilterComparison = .contains
    @State private var value = ""
    @State private var upperValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Filter rows")
                .font(.system(size: 13, weight: .semibold))

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    fieldLabel("Column")
                    Picker("Column", selection: $columnName) {
                        ForEach(tab.descriptor.columns) { column in Text("\(column.name) · \(column.typeLabel)").tag(column.name) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    fieldLabel("Match")
                    Picker("Match", selection: $comparison) {
                        ForEach(ColumnFilterComparison.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
                if comparison.requiresValue {
                    GridRow {
                        fieldLabel(comparison == .between ? "From" : "Value")
                        TextField(comparison == .between ? "Lower value" : "Value", text: $value)
                    }
                    if comparison == .between {
                        GridRow {
                            fieldLabel("To")
                            TextField("Upper value", text: $upperValue)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Apply Filter") {
                    var filters = tab.queryState.columnFilters.filter { $0.columnName != columnName }
                    filters.append(.init(columnName: columnName, value: value, comparison: comparison, upperValue: comparison == .between ? upperValue : nil))
                    tab.updateColumnFilters(filters)
                }
                .buttonStyle(.studioPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(columnName.isEmpty)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Active")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear all") { tab.updateColumnFilters([]) }
                        .buttonStyle(.studioQuiet)
                        .controlSize(.mini)
                        .disabled(!tab.hasColumnFilters)
                }
                if tab.queryState.sanitizedFilters.isEmpty {
                    Text("No column filters")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                }
                ForEach(Array(tab.queryState.sanitizedFilters.enumerated()), id: \.offset) { _, filter in
                    HStack(spacing: 8) {
                        Text("\(filter.columnName): \(filter.comparison.label)\(filter.comparison.requiresValue ? " \(filter.value)" : "")\(filter.upperValue.map { " – \($0)" } ?? "")")
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button { tab.updateColumnFilters(tab.queryState.columnFilters.filter { $0 != filter }) } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.studioIcon)
                        .controlSize(.mini)
                        .help("Remove filter")
                        .accessibilityLabel("Remove filter")
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 2)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(16)
        .frame(width: 380)
        // A popover follows the system appearance even when it opens from a pane.
        .studioSurface(.adaptive)
        .onAppear { columnName = tab.descriptor.columns.first?.name ?? "" }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}
