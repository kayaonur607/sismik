import SwiftUI
import MapKit

// MARK: - Yer satırı

/// Ayarlar listesinde tek bir takip edilen yer.
///
/// Satır tek başına okunabilen bir kuraldır: ad, yarıçap ve büyüklük eşiği.
/// Eşik, uygulamanın kendi büyüklük renk skalasıyla (`MagnitudeLevel`) aynı
/// renkte gösterilir — kullanıcı listede ve haritada gördüğü renkle ayarında
/// gördüğü rengi eşleştirebilsin diye.
struct NotificationPlaceRow: View {
    let place: NotificationPlace

    var body: some View {
        HStack(spacing: 12) {
            PlaceIconBadge(icon: place.icon, size: 30, dimmed: !place.isActive)
                .opacity(place.isActive ? 1 : 0.55)

            VStack(alignment: .leading, spacing: 1) {
                Text(place.name)
                    .font(.body)
                    .foregroundStyle(place.isActive ? Color.primary : Color.secondary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if place.hasValidCoordinate {
                        Text(String(format: "%.0f km", place.radiusKm))
                        Text("·")
                        Text("M \(place.minMagnitude.formatted(.number.precision(.fractionLength(1))))+")
                            .foregroundStyle(MagnitudeLevel(magnitude: place.minMagnitude).textColor)
                            .fontWeight(.semibold)
                        if let critical = place.criticalMagnitude {
                            Text("·")
                            // Kritik uyarı eşiği satırda görünür: hangi yerin
                            // sessiz modu aşacağı ayarlara girmeden anlaşılır.
                            Label("M \(critical.formatted(.number.precision(.fractionLength(1))))+",
                                  systemImage: "exclamationmark.triangle.fill")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(Color(red: 0.80, green: 0.10, blue: 0.12))
                                .fontWeight(.semibold)
                                .accessibilityLabel(L("places.editor.critical.threshold"))
                        }
                    } else {
                        Text(L("places.awaitingLocation"))
                    }
                    if !place.enabled {
                        Text("·")
                        Text(L("places.disabled"))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentTransition(.numericText())
    }
}

// MARK: - Etkin yer yok uyarısı

/// Bildirimler açık ama tek bir etkin yer yoksa kullanıcı sessizce
/// bildirimsiz kalır. Bu şerit kapatılamaz; yer eklenince kaybolur.
struct NoActivePlaceWarning: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(red: 0.80, green: 0.10, blue: 0.12))

            VStack(alignment: .leading, spacing: 2) {
                Text(L("places.noneWarning.title"))
                    .font(.subheadline.weight(.semibold))
                Text(L("places.noneWarning.body"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Eski kural (güncelleme sonrası geçiş)

/// 2.0.9'dan güncelleyen, henüz yer kaydetmemiş kullanıcıya hangi kuralın
/// hâlâ geçerli olduğunu söyler.
///
/// Boş liste + "yer yok" uyarısı burada yanlış olurdu: kullanıcı bildirim
/// almaya DEVAM ediyor. Kart bunu açıkça yazar, kuralı tek satırda özetler
/// ve yer modeline geçişin tek adımını gösterir.
struct LegacyRulesCard: View {
    let rules: NotificationPlacesStore.LegacyRules
    let onAddPlace: () -> Void

    private var summary: String {
        let region = rules.nearbyOnly
            ? L("places.legacy.radius", Int(rules.radiusKm.rounded()))
            : L("places.legacy.allRegions")
        return "\(rules.source.uppercased()) · M \(String(format: "%.1f", rules.minMagnitude))+ · \(region)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.appAction)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L("places.legacy.title"))
                        .font(.subheadline.weight(.semibold))
                    Text(summary)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.appAction)
                    Text(L("places.legacy.body"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button(action: onAddPlace) {
                Label(L("places.legacy.action"), systemImage: "plus.circle.fill")
            }
            .buttonStyle(SismikPrimaryButtonStyle(height: 44, font: .subheadline.weight(.semibold)))
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Premium tanıtımı (kilitli durum)

/// Premium olmayan kullanıcıya özelliğin KENDİSİNİ gösterir.
///
/// Asma kilit ikonu bilinçli olarak yok: kilit, özelliğin ne işe yaradığını
/// anlatmadan yalnızca "yasak" der. Bunun yerine gerçek satırların aynısıyla
/// çizilmiş örnek yerler duruyor — kullanıcı ne satın alacağını görüyor.
/// Liste aşağı doğru yumuşakça soluyor; kesilmiş değil, devam ediyor hissi
/// veriyor ve gözü doğal olarak alttaki eyleme indiriyor.
struct NotificationPlacesLockedPreview: View {
    let onUpgrade: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// Örnek yerler; yer türü uygulamanın dilinde, şehir adı özel isim.
    private static var samples: [NotificationPlace] {
        [
            NotificationPlace(id: "s1", name: "\(L("places.sample.home")) · Kadıköy", icon: .house,
                              latitude: 40.99, longitude: 29.03, radiusKm: 50, minMagnitude: 2.0),
            NotificationPlace(id: "s2", name: "\(L("places.sample.family")) · İzmir", icon: .family,
                              latitude: 38.42, longitude: 27.14, radiusKm: 100, minMagnitude: 3.0),
            NotificationPlace(id: "s3", name: "\(L("places.sample.work")) · Tokyo", icon: .work,
                              latitude: 35.68, longitude: 139.69, radiusKm: 150, minMagnitude: 4.0)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                ForEach(Array(Self.samples.enumerated()), id: \.element.id) { index, place in
                    NotificationPlaceRow(place: place)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)
                        .animation(
                            reduceMotion ? nil
                                : SismikDesign.Motion.entranceSpring.delay(Double(index) * 0.07),
                            value: appeared
                        )
                    if place.id != Self.samples.last?.id {
                        Divider().padding(.leading, 42)
                    }
                }
            }
            // Alt kenara doğru solma: liste burada bitmiyor, devam ediyor.
            .mask(
                LinearGradient(
                    colors: [.black, .black, .black.opacity(0.25)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 3) {
                Text(L("places.locked.title", NotificationPlacesStore.premiumLimit))
                    .font(.subheadline.weight(.semibold))
                Text(L("places.locked.body"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onUpgrade) {
                Text(L("places.locked.cta"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SismikPrimaryButtonStyle(tint: Color.appAction))
        }
        .padding(.vertical, 6)
        .onAppear { appeared = true }
    }
}

// MARK: - Boş durum

struct NotificationPlacesEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(L("places.empty.title"))
                .font(.subheadline.weight(.semibold))
            Text(L("places.empty.body"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

// MARK: - Dünya geneli

/// Kayıtlı yerlerden bağımsız, dünya genelindeki büyük depremler.
///
/// Ücretsiz kullanıcıda eşik sabittir (M6.0+); premium eşiği kendisi seçer.
struct MajorAlertsSection: View {
    @Bindable var settings: NotificationSettings
    let isPremium: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $settings.worldMajorEnabled) {
                label(
                    L("notif.major.world.title"),
                    isPremium
                        ? String(format: L("notif.major.world.subtitle.custom"),
                                 settings.worldMajorThreshold.formatted(.number.precision(.fractionLength(1))))
                        : L("notif.major.world.subtitle")
                )
            }
            .tint(Color.appAction)

            if isPremium, settings.worldMajorEnabled {
                HStack {
                    Text(L("places.threshold"))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("M \(settings.worldMajorThreshold.formatted(.number.precision(.fractionLength(1))))+")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(MagnitudeLevel(magnitude: settings.worldMajorThreshold).textColor)
                }
                Slider(value: $settings.worldMajorThreshold, in: 5...8, step: 0.1)
                    .tint(Color.appAction)
                    .accessibilityLabel(L("notif.major.world.title"))
            }
        }
        .padding(.vertical, 4)
        .animation(SismikDesign.Motion.rowSpring, value: settings.worldMajorEnabled)
    }

    private func label(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.subheadline.weight(.bold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Kendiliğinden eklenen yer

/// Bildirim izni verildiğinde "Bulunduğum yer" kendiliğinden eklenir. Bu kart
/// listede bir kez, kullanıcı kapatana ya da düzenlemeye gidene kadar durur:
/// neyin takip edildiğini ve nereden değiştirileceğini söyler.
struct AutoPlaceNoticeCard: View {
    let place: NotificationPlace
    let onEdit: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ListInfoCard(
            icon: "bell.badge.fill",
            title: L("places.auto.title"),
            message: L("places.auto.body",
                       Int(place.radiusKm.rounded()),
                       place.minMagnitude.formatted(.number.precision(.fractionLength(1)))),
            actionTitle: L("places.auto.edit"),
            actionIcon: "slider.horizontal.3",
            action: onEdit,
            onDismiss: onDismiss
        )
    }
}
