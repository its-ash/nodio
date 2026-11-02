import Combine
import Foundation

/// Owns every model file, keeps the chosen speech model loaded, and
/// keeps the VAD file present while VAD is on.
final class ModelCenter: ObservableObject {
    let stores: [String: WhisperModelStore]
    let vad = WhisperModelStore(file: .vad)

    @Published private(set) var loadedID: String?
    @Published private(set) var loadingID: String?
    @Published private(set) var status = "Model: Not Downloaded"
    @Published private(set) var canRetry = false

    /// Coarse state of the active model, for the menu bar icon, HUD, and setup guide.
    enum Phase: Equatable {
        case missing, downloading(Double), verifying, loading, ready, failed(String)

        var hudMessage: String {
            switch self {
            case .missing: "Model not downloaded"
            case .downloading(let p): "Downloading model… \(Int(p * 100))%"
            case .verifying: "Checking model…"
            case .loading: "Loading model…"
            case .ready: "Ready"
            case .failed: "Model download failed"
            }
        }
    }
    @Published private(set) var phase: Phase = .missing

    /// Called once when a model that was downloaded during this run is loaded.
    var onReadyAfterDownload: (() -> Void)?
    private var downloadedThisRun = false

    private let recognizer: SpeechRecognizer
    private let settings = AppSettings.shared
    private var bag = Set<AnyCancellable>()

    init(recognizer: SpeechRecognizer) {
        self.recognizer = recognizer
        stores = Dictionary(uniqueKeysWithValues: ModelFile.speechModels.map { ($0.id, WhisperModelStore(file: $0)) })
        for s in stores.values {
            s.onChange = { [weak self] _ in self?.refresh() }
        }
        vad.onChange = { [weak self] _ in self?.refresh() }

        settings.$modelID.dropFirst().removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.activate() } }
            .store(in: &bag)
        settings.$vad.dropFirst().removeDuplicates()
            .sink { [weak self] on in if on { DispatchQueue.main.async { self?.vad.prepare() } } }
            .store(in: &bag)
    }

    var active: WhisperModelStore { stores[settings.modelID] ?? stores[ModelFile.turbo.id]! }

    var isReady: Bool { recognizer.isReady && loadedID == settings.modelID }

    /// VAD path when VAD is on and its file is ready.
    var vadPath: String? { settings.vad && vad.state == .ready ? vad.fileURL.path : nil }

    /// Main thread. Downloads and loads the chosen model.
    func activate() {
        if settings.vad { vad.prepare() }
        if active.state == .ready { load(active) } else { active.prepare() }
        refresh()
    }

    func retry() {
        if case .failed = active.state { active.prepare() }
        if case .failed = vad.state, settings.vad { vad.prepare() }
    }

    /// Deletes a downloaded model. The active model is downloaded again.
    func delete(_ id: String) {
        guard let s = stores[id] else { return }
        s.delete()
        if id == settings.modelID {
            loadedID = nil
            activate()
        }
        refresh()
    }

    private func load(_ store: WhisperModelStore) {
        let id = store.file.id
        guard loadingID == nil, loadedID != id || !recognizer.isReady else { return }
        loadingID = id
        refresh()
        recognizer.load(modelURL: store.fileURL) { [weak self] ok in
            guard let self else { return }
            self.loadingID = nil
            if ok {
                self.loadedID = id
                if self.downloadedThisRun, self.settings.modelID == id {
                    self.downloadedThisRun = false
                    self.onReadyAfterDownload?()
                }
            } else {
                self.loadedID = nil
                store.discardAndRetry()
            }
            // The user may have picked another model during the load.
            if self.settings.modelID != id { self.activate() } else { self.refresh() }
        }
    }

    private func refresh() {
        let a = active
        if a.state == .ready, loadedID != a.file.id, loadingID == nil { load(a) }

        canRetry = false
        switch a.state {
        case .missing: status = "Model: Not Downloaded"
        case .downloading(let p): status = "Downloading \(a.file.title)… \(Int(p * 100))%"
        case .verifying: status = "Verifying Model…"
        case .failed(let reason):
            status = "Model Download Failed (\(reason)) — Retry"
            canRetry = true
        case .ready:
            status = loadingID != nil ? "Loading Model…" : "Model: \(a.file.title) · Indian English"
        }
        if case .failed = vad.state, settings.vad {
            status += " · VAD failed"
            canRetry = true
        }

        switch a.state {
        case .missing: phase = .missing
        case .downloading(let p):
            downloadedThisRun = true
            phase = .downloading(p)
        case .verifying: phase = .verifying
        case .failed(let r): phase = .failed(r)
        case .ready: phase = loadedID == a.file.id && loadingID == nil && recognizer.isReady ? .ready : .loading
        }
    }
}
