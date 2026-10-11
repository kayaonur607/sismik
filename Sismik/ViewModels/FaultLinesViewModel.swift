import Foundation
import MapKit

@MainActor
@Observable
final class FaultLinesViewModel {
    static let shared = FaultLinesViewModel()

    private typealias LoadResult = (segments: [FaultSegment], overlays: [RiskMultiPolyline])

    private(set) var segments: [FaultSegment] = []
    private(set) var overlays: [RiskMultiPolyline] = []
    private(set) var viewState: ViewState<[FaultSegment]> = .idle
    private var loadTask: Task<LoadResult, Error>?

    var isLoading: Bool { viewState.isInitialLoading }
    var errorMessage: String? { viewState.failure?.localizedDescription }

    func load() async {
        guard segments.isEmpty else { return }
        if let loadTask {
            await finish(loadTask)
            return
        }

        viewState = .loading
        let task = Task.detached(priority: .userInitiated) { () -> LoadResult in
            let segs = try await FaultLineService.loadSegments()
            let computedOverlays = Dictionary(grouping: segs, by: \.risk).map { risk, riskSegments in
                let multi = RiskMultiPolyline(riskSegments.map(\.polyline))
                multi.risk = risk
                return multi
            }
            return (segs, computedOverlays)
        }
        loadTask = task
        await finish(task)
    }

    private func finish(_ task: Task<LoadResult, Error>) async {
        do {
            let result = try await task.value
            if segments.isEmpty {
                segments = result.segments
                overlays = result.overlays
            }
            viewState = .loaded(segments)
        } catch {
            viewState = .error(error)
        }
        loadTask = nil
    }
}
