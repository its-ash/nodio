import Combine
import CryptoKit
import Foundation

/// Downloads, verifies, and deletes one ggml model file in Application Support.
final class WhisperModelStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case missing, downloading(Double), verifying, ready, failed(String)
    }

    let file: ModelFile

    /// Called on main on every state change.
    var onChange: ((State) -> Void)?
    @Published private(set) var state: State = .missing {
        didSet { if state != oldValue { onChange?(state) } }
    }

    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Nodio/Models", isDirectory: true)
    }()

    var fileURL: URL { Self.directory.appendingPathComponent(file.fileName) }
    private var partURL: URL { Self.directory.appendingPathComponent(file.fileName + ".part") }

    init(file: ModelFile) {
        self.file = file
        super.init()
        if isOnDisk { state = .ready }
    }

    var isOnDisk: Bool {
        ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int64) == file.byteSize
    }

    /// Main thread. Uses the cached file if present, else downloads it.
    func prepare() {
        guard task == nil, state != .verifying else { return }
        let fm = FileManager.default
        if isOnDisk { state = .ready; return }
        try? fm.removeItem(at: fileURL)
        do {
            try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        } catch {
            state = .failed("Cannot create model folder")
            return
        }
        let s = session ?? URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        session = s
        task = s.downloadTask(with: file.url)
        state = .downloading(0)
        task?.resume()
    }

    /// Main thread. Stops a running download and removes the file.
    func delete() {
        task?.cancel()
        task = nil
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: partURL)
        state = .missing
    }

    /// Removes a file that failed to load, then downloads it again.
    func discardAndRetry() {
        delete()
        prepare()
    }

    // MARK: - URLSessionDownloadDelegate (main queue)

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        let total = expected > 0 ? expected : file.byteSize
        state = .downloading(min(1, Double(written) / Double(total)))
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            state = .failed("HTTP \(http.statusCode)")
            return
        }
        do {
            try? fm.removeItem(at: partURL)
            try fm.moveItem(at: location, to: partURL)
        } catch {
            state = .failed("Cannot save model")
            return
        }
        state = .verifying
        let part = partURL, dest = fileURL, expected = file
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = Self.verify(part, expected)
            if ok { try? fm.removeItem(at: dest); try? fm.moveItem(at: part, to: dest) } else { try? fm.removeItem(at: part) }
            DispatchQueue.main.async {
                self?.state = ok && fm.fileExists(atPath: dest.path) ? .ready : .failed("Checksum mismatch")
            }
        }
    }

    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        task = nil
        guard let error else { return }
        if (error as? URLError)?.code == .cancelled { return }
        state = .failed(error.localizedDescription)
    }

    private static func verify(_ url: URL, _ file: ModelFile) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        var hasher = SHA256()
        var n: Int64 = 0
        while let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            n += Int64(chunk.count)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return n == file.byteSize && hex == file.sha256
    }
}
