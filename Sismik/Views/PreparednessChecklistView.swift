import SwiftUI

/// Deprem hazırlık kontrol listesi — işaretler yerelde saklanır.
struct PreparednessChecklistView: View {
    @AppStorage("prep.checked") private var checkedRaw = ""

    private struct Item: Identifiable { let id: String; let title: String }
    private struct Group: Identifiable { let id = UUID(); let title: String; let items: [Item] }

    private var groups: [Group] {
        [
            Group(title: L("prep.group.bag"), items: [
                Item(id: "water", title: L("prep.item.water")),
                Item(id: "food", title: L("prep.item.food")),
                Item(id: "firstaid", title: L("prep.item.firstaid")),
                Item(id: "flashlight", title: L("prep.item.flashlight")),
                Item(id: "whistle", title: L("prep.item.whistle")),
                Item(id: "powerbank", title: L("prep.item.powerbank")),
                Item(id: "docs", title: L("prep.item.docs")),
                Item(id: "cash", title: L("prep.item.cash")),
                Item(id: "meds", title: L("prep.item.meds"))
            ]),
            Group(title: L("prep.group.home"), items: [
                Item(id: "fixfurniture", title: L("prep.item.fixfurniture")),
                Item(id: "meetpoint", title: L("prep.item.meetpoint")),
                Item(id: "contacts", title: L("prep.item.contacts")),
                Item(id: "gas", title: L("prep.item.gas")),
                Item(id: "assembly", title: L("prep.item.assembly"))
            ])
        ]
    }

    private var checked: Set<String> {
        Set(checkedRaw.split(separator: ",").map(String.init))
    }

    private var totalCount: Int { groups.reduce(0) { $0 + $1.items.count } }
    private var doneCount: Int { checked.count }
    private var progress: Double { totalCount == 0 ? 0 : Double(doneCount) / Double(totalCount) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(String(format: L("prep.progress.format"), doneCount, totalCount))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("%\(Int(progress * 100))")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(.brandOrange)
                    }
                    ProgressView(value: progress)
                        .tint(.appAction)
                }
                .padding(.vertical, 4)
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            }

            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        Button { toggle(item.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: checked.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(checked.contains(item.id) ? Color.brandGreen : Color.secondary)
                                Text(item.title)
                                    .foregroundStyle(.primary)
                                    .strikethrough(checked.contains(item.id), color: .secondary)
                                Spacer()
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle(L("prep.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ id: String) {
        var set = checked
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        checkedRaw = set.sorted().joined(separator: ",")
    }
}
