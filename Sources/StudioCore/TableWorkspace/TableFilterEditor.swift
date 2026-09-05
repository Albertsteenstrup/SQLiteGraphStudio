import SwiftUI

struct TableFilterEditor: View {
    let tab: TableTabModel
    @State private var columnName = ""
    @State private var comparison: ColumnFilterComparison = .contains
    @State private var value = ""
    @State private var upperValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filter rows").font(.headline)
            Picker("Column", selection: $columnName) {
                ForEach(tab.descriptor.columns) { column in Text("\(column.name) · \(column.typeLabel)").tag(column.name) }
            }
            Picker("Match", selection: $comparison) {
                ForEach(ColumnFilterComparison.allCases) { Text($0.label).tag($0) }
            }
            if comparison.requiresValue {
                TextField(comparison == .between ? "Lower value" : "Value", text: $value)
                if comparison == .between { TextField("Upper value", text: $upperValue) }
            }
            Button("Apply Filter") {
                var filters = tab.queryState.columnFilters.filter { $0.columnName != columnName }
                filters.append(.init(columnName: columnName, value: value, comparison: comparison, upperValue: comparison == .between ? upperValue : nil))
                tab.updateColumnFilters(filters)
            }.disabled(columnName.isEmpty)
            Divider()
            if tab.queryState.sanitizedFilters.isEmpty { Text("No column filters").foregroundStyle(.secondary) }
            ForEach(Array(tab.queryState.sanitizedFilters.enumerated()), id: \.offset) { _, filter in
                HStack {
                    Text("\(filter.columnName): \(filter.comparison.label)\(filter.comparison.requiresValue ? " \(filter.value)" : "")\(filter.upperValue.map { " – \($0)" } ?? "")").font(.caption)
                    Spacer()
                    Button { tab.updateColumnFilters(tab.queryState.columnFilters.filter { $0 != filter }) } label: { Image(systemName: "xmark") }
                        .help("Remove filter")
                }
            }
            Button("Clear Column Filters") { tab.updateColumnFilters([]) }.disabled(!tab.hasColumnFilters)
        }
        .textFieldStyle(.roundedBorder)
        .padding(18)
        .frame(width: 400)
        .onAppear { columnName = tab.descriptor.columns.first?.name ?? "" }
    }
}
