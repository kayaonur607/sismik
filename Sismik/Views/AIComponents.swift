import SwiftUI

/// Sismolojik değerlendirme kartı. Detay sayfasından ayrı tutulur ki analiz
/// durumu harita ve şiddet kartlarını yeniden çizmesin.
struct SeismicAssessmentCard: View {
    let analysis: AIAnalysisResult?
    let isAnalyzing: Bool
    let failed: Bool
    let onRunAnalysis: () -> Void
    let onSelectQuestion: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var analysisTap = 0
    @State private var questionTap = 0

    /// Kartın üç durumu tek bir karşılaştırılabilir değere indirilir; geçiş
    /// animasyonu buna bağlanır. Üç ayrı bayrağa ayrı ayrı animasyon bağlamak,
    /// yükleme bitip sonuç gelirken iki geçişin üst üste binmesine yol açıyor.
    private enum Phase: Equatable { case idle, loading, result }

    private var phase: Phase {
        if analysis != nil { return .result }
        if isAnalyzing { return .loading }
        return .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.brandOrange)
                Text(L("detail.aiAnalysis"))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
            }

            Divider()

            if let analysis {
                analysisBody(analysis)
                    .transition(.opacity)
            } else if isAnalyzing {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.brandOrange)
                    Text(L("detail.ai.loading"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            } else {
                idleBody
                    .transition(.opacity)
            }
        }
        // Kart boşta → yükleniyor → sonuç arasında geçişsiz sıçrıyordu: detay
        // akışının ortasında oturduğu için her sıçrama altındaki tüm kartları
        // kaydırıyordu. Yükseklik ve içerik artık birlikte yumuşuyor.
        .animation(reduceMotion ? nil : SismikDesign.Motion.rowSpring, value: phase)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SismikDesign.Radius.card, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .sensoryFeedback(.impact(weight: .medium), trigger: analysisTap)
        .sensoryFeedback(.selection, trigger: questionTap)
    }

    @ViewBuilder
    private func analysisBody(_ analysis: AIAnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Doğrulanmış alan verisi ile yorum metni ayrı okunur. İkisi aynı
            // aralıkla dizildiğinde kart tek bir ayrışmamış metin bloğu gibi
            // görünüyordu; ayraç ikisi arasında okuma ritmi kuruyor.
            VStack(alignment: .leading, spacing: 10) {
                factRow(label: L("detail.faultLine"), value: analysis.faultZone)
                factRow(label: L("detail.quakeType"), value: analysis.quakeType)
            }

            Divider()

            Text(analysis.commentary)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

            if let questions = analysis.questions, !questions.isEmpty {
                questionList(questions)
            }

            // Kaynak notu kartın en altında durur. Yorum paragrafının hemen
            // altındayken iki sorun vardı: metne sıkışıyordu ve altındaki gri
            // "Bu olay hakkında" etiketiyle üst üste binip hangisinin hangi
            // bölüme ait olduğu okunmuyordu. Rengi de `.tertiary` yerine
            // `.secondary`: 11pt'de üçüncül ton okunabilirliğin altında kalıyor.
            Divider()

            Text(L("detail.aiFooter"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Olayla ilgili konu başlıkları.
    ///
    /// Eskiden her satırın solunda 2×18pt turuncu bir çentik, sağında da
    /// metnin baseline'ından aşağı kaymış bir ok vardı. Bu düzen satırları
    /// sohbet öneri balonlarına benzetiyordu; çentik de hiçbir şeyi
    /// kodlamadığı için salt dekoratif kalıyordu. Şimdi satırlar standart
    /// iOS açıklama satırı: metin, dikey ortalanmış ok, aralarında ayraç.
    private func questionList(_ questions: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("detail.ai.questions"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            // `id: \.element` — sorular benzersiz metinler ve kartın ömrü
            // boyunca değişmiyor; konum tabanlı `\.offset` kimliği yerine
            // öğenin kendisi kullanılır.
            ForEach(Array(questions.enumerated()), id: \.element) { index, question in
                if index > 0 { Divider() }
                Button {
                    questionTap += 1
                    onSelectQuestion(question)
                } label: {
                    HStack(spacing: 10) {
                        Text(question)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(L("detail.ai.question.hint"))
            }
        }
    }

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("detail.ai.intro"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Düz metin etiket: `sparkles` glifi bu düğmeyi bir "üretken içerik"
            // eylemi gibi gösteriyordu. Kart, kaynağın yayımladığı büyüklük,
            // derinlik ve fay verisinden bir sismoloji özeti derliyor; düğme de
            // uygulamanın diğer birincil eylemleri gibi görünmeli.
            Button {
                analysisTap += 1
                onRunAnalysis()
            } label: {
                Text(L("detail.ai.action"))
            }
            .buttonStyle(.sismikPrimary)
            .disabled(isAnalyzing)

            if failed {
                Text(L("detail.ai.unavailable"))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : SismikDesign.Motion.rowSpring, value: failed)
    }

    private func factRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Önizlemeler

/// Kartın üç durumu ağ/premium gerektirmeden görülebilsin diye örnek sonuç.
private let previewAnalysis = AIAnalysisResult(
    faultZone: "Kuzey Anadolu Fay Zonu — Gemlik segmenti",
    quakeType: "Sığ odaklı, doğrultu atımlı kırılma",
    commentary: """
    Olay 7,4 km derinlikte, doğrultu atımlı bir segmentte gerçekleşti. \
    Bu derinlikteki kırılmalar yüzeyde daha kısa süreli ama daha keskin \
    bir sarsıntı üretir; hissedilme alanı büyüklüğe göre dar kalır.
    """,
    questions: [
        "Bu derinlik neden önemli?",
        "Bölgede artçı beklenir mi?"
    ]
)

#Preview("Değerlendirme - Sonuç") {
    SeismicAssessmentCard(
        analysis: previewAnalysis,
        isAnalyzing: false,
        failed: false,
        onRunAnalysis: {},
        onSelectQuestion: { _ in }
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("Değerlendirme - Boşta") {
    SeismicAssessmentCard(
        analysis: nil,
        isAnalyzing: false,
        failed: false,
        onRunAnalysis: {},
        onSelectQuestion: { _ in }
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("Değerlendirme - Yükleniyor") {
    SeismicAssessmentCard(
        analysis: nil,
        isAnalyzing: true,
        failed: false,
        onRunAnalysis: {},
        onSelectQuestion: { _ in }
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("Değerlendirme - Hata") {
    SeismicAssessmentCard(
        analysis: nil,
        isAnalyzing: false,
        failed: true,
        onRunAnalysis: {},
        onSelectQuestion: { _ in }
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}

#Preview("Değerlendirme - Koyu") {
    SeismicAssessmentCard(
        analysis: previewAnalysis,
        isAnalyzing: false,
        failed: false,
        onRunAnalysis: {},
        onSelectQuestion: { _ in }
    )
    .padding()
    .background(Color(.systemGroupedBackground))
    .preferredColorScheme(.dark)
}
