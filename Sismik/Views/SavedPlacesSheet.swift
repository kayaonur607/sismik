import SwiftUI
import CoreLocation

/// Favori yerler listesi.
///
/// Buradaki her kayıt tamamen cihazda saklanır ve ağ olmadan da açılabilir;
/// yol tarifi düğmesi çevrimdışıyken pusula ekranına düşer.
struct SavedPlacesSheet: View {
    let origin: CLLocation?
    let onSelect: (AssemblyArea) -> Void

    @Environment(\.dismiss) private var dismiss
    private let store = SavedPlacesStore.shared
    @State private var offlineTarget: SavedPlace?
    @State private var editingNoteFor: SavedPlace?
    @State private var noteDraft = ""

    var body: some View {
        // Sıralama gövde başına bir kez yapılır; `ForEach` ve `onDelete` aynı
        // diziyi paylaşır (daha önce her ikisi de ayrı ayrı sıralıyordu).
        let ranked = store.ranked(from: origin)
        NavigationStack {
            Group {
                if store.places.isEmpty {
                    ContentUnavailableView {
                        Label(L("favorites.empty.title"), systemImage: "star")
                    } description: {
                        Text(L("favorites.empty.detail"))
                    }
                } else {
                    List {
                        ForEach(ranked) { entry in
                            row(entry)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                        .onDelete { offsets in
                            offsets.map { ranked[$0].id }.forEach(store.remove(id:))
                        }

                        Text(L("favorites.footer"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(L("favorites.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.close")) { dismiss() }
                }
            }
            .navigationDestination(item: $offlineTarget) { place in
                OfflineDirectionsView(
                    name: place.name,
                    address: place.address,
                    coordinate: place.coordinate
                )
            }
            .alert(L("favorites.note"), isPresented: noteAlertBinding) {
                TextField(L("favorites.note.placeholder"), text: $noteDraft)
                Button(L("common.close"), role: .cancel) { editingNoteFor = nil }
                Button(L("common.save")) {
                    if let editingNoteFor {
                        store.updateNote(id: editingNoteFor.id, note: noteDraft)
                    }
                    editingNoteFor = nil
                }
            }
        }
    }

    private var noteAlertBinding: Binding<Bool> {
        Binding(
            get: { editingNoteFor != nil },
            set: { if !$0 { editingNoteFor = nil } }
        )
    }

    private func row(_ entry: RankedSavedPlace) -> some View {
        let place = entry.place
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AssemblyAreaMarker(size: 34, category: place.category)

                VStack(alignment: .leading, spacing: 3) {
                    Text(place.name)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(2)
                    if let address = place.address, !address.isEmpty {
                        Text(address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 4)

                // Uzaklık sıralama sırasında ölçüldü; satır çiziminde yeniden
                // `CLLocation` ayırıp jeodezik hesap yapmaya gerek yok.
                if let distance = entry.distanceMeters {
                    Text(OfflineDirectionsView.distanceText(distance))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(Color.appAction)
                }
            }

            if let note = place.note, !note.isEmpty {
                Label(note, systemImage: "text.quote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                Button {
                    onSelect(place.asAssemblyArea(distanceFrom: origin))
                    dismiss()
                } label: {
                    Label(L("favorites.onMap"), systemImage: "map")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    offlineTarget = place
                } label: {
                    Label(L("favorites.findDirection"), systemImage: "location.north.line.fill")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.appAction.opacity(0.14), in: Capsule())
                        .foregroundStyle(Color.appAction)
                }
                .buttonStyle(.plain)

                Button {
                    noteDraft = place.note ?? ""
                    editingNoteFor = place
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.caption.weight(.bold))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("favorites.addNote"))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }
}
