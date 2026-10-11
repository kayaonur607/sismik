import Foundation

/// Deprem için sismolojik değerlendirme raporu üretir.
///
/// Üretim YALNIZCA sunucudaki Gemini çağrısıyla yapılır; yerel/uydurma yanıt yok.
/// Öncelik: cihaz önbelleği → Firebase `/ai`. Çevrimdışıysa veya üretilemezse `nil`.
struct AIAnalysisResult: Codable, Sendable, Equatable {
    let faultZone: String
    let quakeType: String
    let commentary: String
    let questions: [String]?
}

enum AIService {

    /// Önbellek anahtarı sürümü: büyüklük/derinlik revizyonu eski kaydı geçersiz kılar.
    private static let cacheVersion = "v7"

    static func fetchAnalysis(for eq: Earthquake) async -> AIAnalysisResult? {
        let languageSuffix = AppLanguage.currentLanguageCode
        let cacheKey = cacheKey(for: eq, lang: languageSuffix)

        return await AIAnalysisCache.shared.coalesced(cacheKey) {
            if let cached = await AIAnalysisCache.shared.get(cacheKey),
               let result = decodeResult(cached) {
                AppLog.ai.info("analysis cache hit")
                return result
            }

            if let raw = await fetchFromBackend(eq: eq, lang: languageSuffix),
               let result = decodeResult(raw) {
                await AIAnalysisCache.shared.set(cacheKey, raw)
                AppLog.ai.info("analysis server result cached")
                return result
            }

            AppLog.ai.error("analysis unavailable")
            return nil
        }
    }

    private static func cacheKey(for eq: Earthquake, lang: String) -> String {
        let mag = String(format: "%.1f", eq.magnitude)
        let depth = String(format: "%.0f", eq.depth)
        return "\(cacheVersion)_\(eq.id)_\(lang)_\(mag)_\(depth)"
    }

    /// Gemini bazen JSON'u ```json çitleri içinde döndürür; toleranslı çözümle.
    private static func stripCodeFence(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func decodeResult(_ raw: String) -> AIAnalysisResult? {
        let text = stripCodeFence(raw)
        guard let data = text.data(using: .utf8),
              let result = try? JSONDecoder().decode(AIAnalysisResult.self, from: data),
              !result.faultZone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !result.commentary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return result
    }

    // MARK: - Sunucu çağrısı (/ai)

    private static func fetchFromBackend(eq: Earthquake, lang: String) async -> String? {
        var comps = URLComponents(string: BackendConfig.baseURL + "/ai")
        comps?.queryItems = [
            URLQueryItem(name: "id", value: eq.id),
            URLQueryItem(name: "lang", value: lang),
            URLQueryItem(name: "mag", value: "\(eq.magnitude)"),
            URLQueryItem(name: "depth", value: "\(eq.depth)"),
            URLQueryItem(name: "lat", value: "\(eq.coordinate.latitude)"),
            URLQueryItem(name: "lon", value: "\(eq.coordinate.longitude)"),
            URLQueryItem(name: "place", value: eq.displayTitle)
        ]
        guard let url = comps?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.cachePolicy = .useProtocolCachePolicy
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200 else {
                AppLog.ai.error("server analysis http=\(http.statusCode, privacy: .public)")
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch {
            AppLog.ai.error("server analysis network error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func askQuestion(_ question: String, for eq: Earthquake) async -> String? {
        let languageSuffix = AppLanguage.currentLanguageCode

        var comps = URLComponents(string: BackendConfig.baseURL + "/ai/ask")
        comps?.queryItems = [
            URLQueryItem(name: "id", value: eq.id),
            URLQueryItem(name: "lang", value: languageSuffix),
            URLQueryItem(name: "mag", value: "\(eq.magnitude)"),
            URLQueryItem(name: "depth", value: "\(eq.depth)"),
            URLQueryItem(name: "lat", value: "\(eq.coordinate.latitude)"),
            URLQueryItem(name: "lon", value: "\(eq.coordinate.longitude)"),
            URLQueryItem(name: "place", value: eq.displayTitle),
            URLQueryItem(name: "q", value: question)
        ]
        guard let url = comps?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            struct AnswerResult: Codable {
                let answer: String
            }

            if let result = try? JSONDecoder().decode(AnswerResult.self, from: data) {
                let answer = result.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                return answer.isEmpty ? nil : answer
            }

            let stripped = stripCodeFence(String(data: data, encoding: .utf8) ?? "")
            guard let strippedData = stripped.data(using: .utf8),
                  let result = try? JSONDecoder().decode(AnswerResult.self, from: strippedData) else {
                return nil
            }
            let answer = result.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return answer.isEmpty ? nil : answer
        } catch {
            AppLog.ai.error("ask question error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// İstatistik ekranındaki sayıları sade dilde özetler.
    /// Tekil olay analizinin aksine sonuç kalıcı tutulmaz — istatistikler
    /// değiştiği için sunucudaki kısa süreli (bölge+dil+dönem) önbellek kullanılır.
    static func fetchStatsSummary(
        region: String?,
        rangeLabel: String,
        stats: GlobalStats,
        presentation: StatisticsPresentation
    ) async -> String? {
        let lang = AppLanguage.currentLanguageCode
        var comps = URLComponents(string: BackendConfig.baseURL + "/ai/stats-summary")
        var items = [
            URLQueryItem(name: "region", value: region ?? "global"),
            URLQueryItem(name: "lang", value: lang),
            URLQueryItem(name: "rangeLabel", value: rangeLabel),
            URLQueryItem(name: "total", value: "\(stats.total7d)"),
            URLQueryItem(name: "last24h", value: "\(stats.last24h)"),
            URLQueryItem(name: "maxMagnitude", value: "\(stats.maxMagnitude)"),
            URLQueryItem(name: "avgMagnitude", value: "\(stats.avgMagnitude)"),
            URLQueryItem(name: "avgDepth", value: "\(stats.avgDepth)"),
            URLQueryItem(name: "m45plus", value: "\(stats.m45plus)"),
            URLQueryItem(name: "activityChangePercent", value: "\(presentation.activityChangePercent)")
        ]
        if !stats.strongestTitle.isEmpty {
            items.append(URLQueryItem(name: "strongestTitle", value: stats.strongestTitle))
        }
        if let topRegion = presentation.topRegions.first {
            items.append(URLQueryItem(name: "topRegionName", value: topRegion.name))
            items.append(URLQueryItem(name: "topRegionCount", value: "\(topRegion.count)"))
        }
        comps?.queryItems = items
        guard let url = comps?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            struct SummaryResult: Codable {
                let summary: String
            }
            let result = try JSONDecoder().decode(SummaryResult.self, from: data)
            let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? nil : summary
        } catch {
            AppLog.ai.error("stats summary error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

}

// MARK: - Kalıcı analiz cache'i

/// Üretilmiş analizleri deprem kimliği + büyüklük/derinlik anahtarına göre saklar.
actor AIAnalysisCache {
    static let shared = AIAnalysisCache()

    private var memory: [String: String] = [:]
    private var insertionOrder: [String] = []
    private var isLoaded = false
    private let maxEntries = 500
    private var loadTask: Task<[String: String], Never>?
    private var inFlight: [String: Task<AIAnalysisResult?, Never>] = [:]
    private var isPersisting = false
    private var persistNeeded = false

    nonisolated private var fileURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("sismik_ai_analysis_cache.json")
    }

    private init() {}

    func coalesced(_ key: String, work: @escaping @Sendable () async -> AIAnalysisResult?) async -> AIAnalysisResult? {
        if let existing = inFlight[key] {
            return await existing.value
        }
        let task = Task { await work() }
        inFlight[key] = task
        let value = await task.value
        inFlight[key] = nil
        return value
    }

    private func ensureLoaded() async {
        guard !isLoaded else { return }

        if loadTask == nil {
            let url = fileURL
            loadTask = Task {
                await Task.detached(priority: .medium) { () -> [String: String] in
                    guard let data = try? Data(contentsOf: url),
                          let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
                        return [:]
                    }
                    return decoded
                }.value
            }
        }

        if let dict = await loadTask?.value {
            self.memory = dict
            self.insertionOrder = Array(dict.keys)
            self.isLoaded = true
        }
    }

    func get(_ id: String) async -> String? {
        await ensureLoaded()
        return memory[id]
    }

    func set(_ id: String, _ text: String) async {
        await ensureLoaded()
        if memory[id] == nil {
            insertionOrder.append(id)
        } else if let idx = insertionOrder.firstIndex(of: id) {
            insertionOrder.remove(at: idx)
            insertionOrder.append(id)
        }
        memory[id] = text
        while memory.count > maxEntries, let drop = insertionOrder.first {
            insertionOrder.removeFirst()
            memory.removeValue(forKey: drop)
        }
        schedulePersist()
    }

    private func schedulePersist() {
        persistNeeded = true
        guard !isPersisting else { return }
        isPersisting = true
        persistNeeded = false
        let dictToSave = memory
        let url = fileURL
        Task {
            await Task.detached(priority: .background) {
                if let data = try? JSONEncoder().encode(dictToSave) {
                    try? data.write(to: url, options: .atomic)
                }
            }.value
            isPersisting = false
            if persistNeeded {
                schedulePersist()
            }
        }
    }
}
