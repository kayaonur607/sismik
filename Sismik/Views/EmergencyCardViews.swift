import SwiftUI

/// Acil sağlık, kimlik ve evcil hayvan bilgi kartları.
struct EmergencyCardSectionView: View {
    /// Acil durum ekranının ölçü sistemi — kapsayıcı tarafından ölçülüp
    /// ortamla iletilir, burada ikinci kez hesaplanmaz.
    @Environment(\.emergencyLayout) private var layout

    @State private var store = EmergencyCardStore.shared
    /// Açık olan kart sayfası. Daha önce üç ayrı `.sheet` (`isPresented` + iki
    /// `item`) aynı görünüme bağlıydı; SwiftUI aynı seviyedeki birden çok sheet
    /// sunumunda yalnızca birini canlı tutuyor, "Kart Ekle" sayfası bu yüzden
    /// hiç açılmıyordu. Tek sheet + yönlendirme bunu kesin olarak çözer.
    @State private var route: CardRoute?

    private enum CardRoute: Identifiable {
        case add
        case edit(EmergencyCard)
        case inspect(EmergencyCard)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let card): "edit-\(card.id)"
            case .inspect(let card): "inspect-\(card.id)"
            }
        }
    }

    private var isTR: Bool { AppLanguage.isTurkish }

    var body: some View {
        VStack(alignment: .leading, spacing: layout.itemSpacing) {
            // Başlıkta ayrı bir "Kart Ekle" düğmesi yok: ekleme, kart yokken
            // boş durum satırından, kart varken listenin sonundaki ekleme
            // kutusundan yapılır — eylem her zaman içeriğin kendi yanında.
            HStack(spacing: 8) {
                Image(systemName: "heart.text.square.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.red)
                    .frame(width: layout.iconBox, height: layout.iconBox)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                Text(L("Acil Sağlık & Kimlik Kartları"))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)
            }
            .frame(minHeight: layout.sectionHeaderHeight)

            if store.cards.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: layout.itemSpacing) {
                        ForEach(store.cards) { card in
                            cardTile(card)
                        }
                        addCardTile
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(layout.surfacePadding)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: layout.surfaceRadius, style: .continuous))
        .sheet(item: $route) { route in
            switch route {
            case .add:
                EmergencyCardEditorView(card: EmergencyCard()) { newCard in
                    store.add(newCard)
                }
            case .edit(let card):
                EmergencyCardEditorView(card: card) { updatedCard in
                    store.update(updatedCard)
                }
            case .inspect(let card):
                EmergencyCardModalView(card: card)
            }
        }
    }

    private var emptyState: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            route = .add
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "cross.case.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.red)
                    .frame(width: 40, height: 40)
                    .background(Color.red.opacity(0.11), in: .rect(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Acil Bilgi Kartı Oluştur"))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)

                    Text(L("Sağlık ve acil iletişim bilgilerini ekipler için hazır tut."))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.brandOrange)
                    .frame(width: layout.minimumTapTarget, height: layout.minimumTapTarget)
            }
            // Dolgu ve zemin etiketin içinde: satırın tamamı (boşluklar
            // dahil) dokunulabilir, yalnızca yazı ve ok değil.
            .padding(layout.tilePadding)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: layout.innerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: layout.innerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: layout.innerRadius))
        }
        .buttonStyle(.plain)
    }

    /// Kart listesinin sonunda duran ekleme kutusu. Kesikli çerçeve, onu
    /// dolu kartlardan ayırıp "buraya yeni bir tane gelebilir" der.
    private var addCardTile: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            route = .add
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.brandOrange)
                    .frame(width: layout.iconBox + 8, height: layout.iconBox + 8)
                    .background(Color.brandOrange.opacity(0.12), in: .circle)

                Text(L("Kart Ekle"))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.brandOrange)
            }
            .frame(width: 132)
            .frame(maxHeight: .infinity)
            .padding(layout.tilePadding)
            .contentShape(.rect(cornerRadius: layout.innerRadius))
        }
        .buttonStyle(.sismikPressable(scale: 0.97))
        .background(Color.brandOrange.opacity(0.05), in: .rect(cornerRadius: layout.innerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: layout.innerRadius, style: .continuous)
                .strokeBorder(
                    Color.brandOrange.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                )
        }
        .accessibilityLabel(L("Kart Ekle"))
    }

    private func cardTile(_ card: EmergencyCard) -> some View {
        VStack(spacing: 0) {
            Button {
                route = .inspect(card)
            } label: {
                cardTileSummary(card)
            }
            .buttonStyle(.sismikListRow)

            Divider()
                .padding(.horizontal, 14)

            HStack(spacing: 8) {
                if let callURL = card.callURL {
                    Link(destination: callURL) {
                        compactContactAction(
                            L("Ara"),
                            icon: "phone.fill",
                            tint: .brandGreen
                        )
                    }
                    .accessibilityHint(L("Acil kişiyi telefonla arar"))
                }

                if let smsURL = card.messageURL(body: emergencySMSBody(for: card)) {
                    Link(destination: smsURL) {
                        compactContactAction(
                            "SMS",
                            icon: "message.fill",
                            tint: .brandOrange
                        )
                    }
                    .accessibilityHint(L("Hazır acil durum mesajını açar"))
                }

                Spacer(minLength: 4)

                Menu {
                    Button {
                        route = .inspect(card)
                    } label: {
                        Label(L("Kartı İncele"), systemImage: "doc.text.magnifyingglass")
                    }
                    Button {
                        route = .edit(card)
                    } label: {
                        Label(L("Düzenle"), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        store.delete(id: card.id)
                    } label: {
                        Label(L("Sil"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: layout.minimumTapTarget, height: layout.minimumTapTarget)
                        .contentShape(.rect)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(width: 278)
        .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: layout.innerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: layout.innerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private func cardTileSummary(_ card: EmergencyCard) -> some View {
        VStack(alignment: .leading, spacing: layout.itemSpacing) {
            HStack(spacing: layout.itemSpacing) {
                Image(systemName: card.symbolIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(card.isPet ? Color.orange : Color.red)
                    .frame(width: layout.iconBox, height: layout.iconBox)
                    .background((card.isPet ? Color.orange : Color.red).opacity(0.13), in: .circle)

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name.isEmpty ? (card.isPet ? (L("Evcil Hayvan")) : (L("İsimsiz"))) : card.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(card.relationOrBreed.isEmpty ? (L("Acil bilgi kartı")) : card.relationOrBreed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                Label(card.isPet ? (L("Evcil")) : card.bloodType, systemImage: card.isPet ? "pawprint.fill" : "drop.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(card.isPet ? Color.orange : Color.red)

                if let phone = card.preferredContactPhone {
                    Label(phone, systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if !card.chronicConditions.isEmpty {
                Label(card.chronicConditions, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: layout.identityTileHeight, alignment: .topLeading)
        .padding(layout.tilePadding)
        .contentShape(.rect(cornerRadius: layout.innerRadius))
    }

    private func compactContactAction(_ title: String, icon: String, tint: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(height: layout.minimumTapTarget)
            .background(tint.opacity(0.11), in: .rect(cornerRadius: 12))
    }

    private func emergencySMSBody(for card: EmergencyCard) -> String {
        if isTR {
            return "Sismik acil kartı: \(card.name) için sizinle iletişime geçiyorum. Lütfen mümkün olan en kısa sürede dönüş yapın."
        }
        return "Sismik emergency card: I am contacting you about \(card.name). Please respond as soon as possible."
    }
}

// MARK: - Kart Düzenleme Formu

struct EmergencyCardEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var card: EmergencyCard
    @State private var hasBirthDate: Bool = false
    @State private var selectedBirthDate: Date = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()

    let onSave: (EmergencyCard) -> Void
    private var isTR: Bool { AppLanguage.isTurkish }

    init(card: EmergencyCard, onSave: @escaping (EmergencyCard) -> Void) {
        self.onSave = onSave
        _card = State(initialValue: card)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(L("KART KATEGORİSİ VE SİMGE"))) {
                    Picker("", selection: $card.isPet) {
                        Label(L("Kişi Kartı"), systemImage: "person.crop.circle.fill").tag(false)
                        Label(L("Evcil Hayvan Kartı"), systemImage: "pawprint.fill").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: card.isPet) { _, isPet in
                        card.symbolIcon = isPet ? EmergencyCard.petSymbols[0] : EmergencyCard.personSymbols[0]
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("Simge Seçin"))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)

                        let symbols = card.isPet ? EmergencyCard.petSymbols : EmergencyCard.personSymbols
                        HStack(spacing: 14) {
                            ForEach(symbols, id: \.self) { sym in
                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    card.symbolIcon = sym
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(card.symbolIcon == sym ? Color.brandOrange.opacity(0.18) : Color(.tertiarySystemGroupedBackground))
                                            .frame(width: 44, height: 44)
                                        Image(systemName: sym)
                                            .font(.system(size: 20, weight: .bold))
                                            .foregroundStyle(card.symbolIcon == sym ? Color.brandOrange : .secondary)
                                    }
                                    .overlay(Circle().stroke(card.symbolIcon == sym ? Color.brandOrange : Color.clear, lineWidth: 2))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text(L("KİMLİK BİLGİLERİ & DOĞUM TARİHİ"))) {
                    TextField(card.isPet ? (L("Hayvanın Adı (Örn: Paşa)")) : (L("Ad Soyad")), text: $card.name)

                    TextField(card.isPet ? (L("Cinsi / Irkı (Örn: Golden Retriever)")) : (L("Yakınlık Derecesi (Örn: Kendim, Eşim, Çocuğum)")), text: $card.relationOrBreed)

                    Toggle(L("Doğum Tarihi Ekle"), isOn: $hasBirthDate)

                    if hasBirthDate {
                        DatePicker(L("Doğum Tarihi"), selection: $selectedBirthDate, in: ...Date(), displayedComponents: .date)
                            .datePickerStyle(.compact)
                    }

                    TextField(L("Kendi Telefon Numarası"), text: $card.personalPhone)
                        .keyboardType(.phonePad)

                    TextField(card.isPet ? (L("Veteriner / İletişim Tel No")) : (L("Acil Durum Yakını Telefonu")), text: $card.emergencyContact)
                        .keyboardType(.phonePad)

                    if !card.isPet {
                        TextField(L("TC Kimlik / Pasaport / Sigorta No"), text: $card.nationalIdOrPassport)

                        Picker(L("Kan Grubu"), selection: $card.bloodType) {
                            ForEach(EmergencyCard.bloodTypes, id: \.self) { bt in
                                Text(bt).tag(bt)
                            }
                        }
                    }
                }

                Section(header: Text(L("TIBBİ VE SAĞLIK DURUMU"))) {
                    TextField(L("Kronik Hastalıklar / Alerjiler"), text: $card.chronicConditions)

                    TextField(L("Düzenli Kullanılan İlaçlar"), text: $card.medications)

                    if !card.isPet {
                        Toggle(L("Organ Bağışçısıyım"), isOn: $card.isOrganDonor)
                        Toggle(L("Tıbbi Protez / Kalp Pili / İmplant Var"), isOn: $card.hasMedicalDevice)
                    }
                }

                Section(header: Text(L("AFET ÇANTASI VE ÖZEL NOTLAR"))) {
                    TextField(card.isPet ? (L("Taşıma Çantası / Tasma Konumu")) : (L("Afet Çantası Konumu (Örn: Yatak yanında)")), text: $card.emergencyBagLocation)

                    TextField(card.isPet ? (L("Mikroçip No / Beslenme Notu")) : (L("Özel Notlar / Ek Bilgiler")), text: $card.notes)
                }
            }
            .navigationTitle(card.name.isEmpty ? (L("Acil Bilgi Kartı")) : card.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let b = card.birthDate {
                    hasBirthDate = true
                    selectedBirthDate = b
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("İptal")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Kaydet")) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        card.birthDate = hasBirthDate ? selectedBirthDate : nil
                        onSave(card)
                        dismiss()
                    }
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.brandOrange)
                    .disabled(card.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Büyük Ekran Sağlık & Acil Durum Kartı Modalı

struct EmergencyCardModalView: View {
    @Environment(\.dismiss) private var dismiss
    let card: EmergencyCard

    private var isTR: Bool { AppLanguage.isTurkish }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // Üst Medikal Kimlik Rozeti
                    VStack(spacing: 14) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(card.isPet ? Color.orange.opacity(0.12) : Color.red.opacity(0.12))
                                    .frame(width: 64, height: 64)

                                Image(systemName: card.symbolIcon)
                                    .font(.system(size: 30, weight: .bold))
                                    .foregroundStyle(card.isPet ? Color.orange : Color.red)
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(card.name)
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(.primary)

                                if !card.relationOrBreed.isEmpty {
                                    Text(card.relationOrBreed)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }

                                if let dateStr = card.formattedBirthDate, let age = card.ageText {
                                    Label("\(dateStr) (\(age))", systemImage: "calendar")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }

                        HStack(spacing: 10) {
                            if !card.isPet {
                                HStack(spacing: 6) {
                                    Image(systemName: "drop.fill")
                                        .font(.caption.weight(.bold))
                                    Text("KAN: \(card.bloodType)")
                                        .font(.subheadline.weight(.bold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color.red, in: Capsule())
                            }

                            if card.isOrganDonor {
                                HStack(spacing: 4) {
                                    Image(systemName: "heart.fill")
                                        .font(.caption)
                                    Text(L("Organ Bağışçısı"))
                                        .font(.caption.weight(.bold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.green, in: Capsule())
                            }

                            if card.hasMedicalDevice {
                                HStack(spacing: 4) {
                                    Image(systemName: "bolt.heart.fill")
                                        .font(.caption)
                                    Text(L("Tıbbi İmplant"))
                                        .font(.caption.weight(.bold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.blue, in: Capsule())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )

                    if let callURL = card.callURL,
                       let messageURL = card.messageURL(body: formattedShareText) {
                        HStack(spacing: 12) {
                            Link(destination: callURL) {
                                contactActionLabel(L("Acil Kişiyi Ara"), icon: "phone.fill")
                            }
                            .buttonStyle(.sismikPrimary(tint: .brandGreen))
                            .accessibilityHint(L("Telefon aramasını başlatır"))

                            Link(destination: messageURL) {
                                contactActionLabel(L("SMS Gönder"), icon: "message.fill")
                            }
                            .buttonStyle(.sismikPrimary)
                            .accessibilityHint(L("Kart bilgileriyle SMS oluşturur"))
                        }
                    }

                    // İletişim & Kimlik
                    VStack(alignment: .leading, spacing: 14) {
                        if !card.personalPhone.isEmpty {
                            detailRow(title: L("KENDİ TELEFON NUMARASI"), value: card.personalPhone, icon: "phone.fill", tint: .blue)
                        }

                        if !card.emergencyContact.isEmpty {
                            detailRow(title: card.isPet ? (L("VETERİNER / YAKIN TELEFONU")) : (L("ACİL DURUM İLETİŞİM TELEFONU")), value: card.emergencyContact, icon: "phone.badge.plus", tint: .green)
                        }

                        if !card.nationalIdOrPassport.isEmpty {
                            detailRow(title: L("TC KİMLİK / PASAPORT / SİGORTA NO"), value: card.nationalIdOrPassport, icon: "person.text.square.fill", tint: .purple)
                        }
                    }
                    .padding(20)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )

                    // Tıbbi & Özel Detaylar
                    VStack(alignment: .leading, spacing: 14) {
                        if !card.chronicConditions.isEmpty {
                            detailRow(title: L("KRONİK HASTALIKLAR & ALERJİLER"), value: card.chronicConditions, icon: "exclamationmark.triangle.fill", tint: .orange)
                        }

                        if !card.medications.isEmpty {
                            detailRow(title: L("KULLANILAN DÜZENLİ İLAÇLAR"), value: card.medications, icon: "pill.fill", tint: .purple)
                        }

                        if !card.emergencyBagLocation.isEmpty {
                            detailRow(title: card.isPet ? (L("TAŞIMA ÇANTASI / TASMA KONUMU")) : (L("AFET ÇANTASI KONUMU")), value: card.emergencyBagLocation, icon: "bag.fill", tint: .brandOrange)
                        }

                        if !card.notes.isEmpty {
                            detailRow(title: L("ÖZEL NOTLAR / ÇİP NO / AÇIKLAMA"), value: card.notes, icon: "doc.text.fill", tint: .gray)
                        }
                    }
                    .padding(20)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    )

                    // Paylaş / Metin Kopyala Butonu
                    ShareLink(item: formattedShareText) {
                        HStack(spacing: 8) {
                            Text(L("Kartı SMS / WhatsApp İle Paylaş"))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Image(systemName: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 12)
                    }
                    .buttonStyle(.sismikPrimary)

                    HStack(spacing: 6) {
                        Image(systemName: "internaldrive.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(L("Bu tıbbi kart %100 çevrimdışı çalışır ve cihazınızda yerel saklanır."))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                }
                .padding()
                .sismikContentWidth(compact: .infinity, regular: 640)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(L("Tıbbi Acil Kartı"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("common.close")) { dismiss() }
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Color.brandOrange)
                }
            }
        }
    }

    private func detailRow(title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)

            Divider().padding(.top, 4)
        }
    }

    private func contactActionLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 8)
    }

    private var formattedShareText: String {
        var lines: [String] = []
        lines.append("SİSMİK ACİL DURUM KARTI")
        lines.append("İsim: \(card.name)")
        if !card.relationOrBreed.isEmpty { lines.append("Derece/Irk: \(card.relationOrBreed)") }
        if let d = card.formattedBirthDate, let age = card.ageText { lines.append("Doğum Tarihi: \(d) (\(age))") }
        if !card.personalPhone.isEmpty { lines.append("Kendi Tel: \(card.personalPhone)") }
        if !card.emergencyContact.isEmpty { lines.append("Acil Tel: \(card.emergencyContact)") }
        if !card.isPet { lines.append("Kan Grubu: \(card.bloodType)") }
        if !card.chronicConditions.isEmpty { lines.append("Kronik Hastalık/Alerji: \(card.chronicConditions)") }
        if !card.medications.isEmpty { lines.append("İlaçlar: \(card.medications)") }
        if !card.emergencyBagLocation.isEmpty { lines.append("Afet Çantası Konumu: \(card.emergencyBagLocation)") }
        if !card.notes.isEmpty { lines.append("Notlar: \(card.notes)") }
        return lines.joined(separator: "\n")
    }
}
