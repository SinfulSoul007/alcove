/// Reader's load lifecycle is independent of WebKit callback timing.
struct ReaderLoadState: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case loading, ready, failed(String), closed }
    private(set) var phase: Phase = .loading
    private(set) var isLoadingDocument = false

    mutating func beginDocument() -> Bool {
        guard phase == .loading, !isLoadingDocument else { return false }
        isLoadingDocument = true; return true
    }
    mutating func finishDocument() -> Bool {
        guard phase == .loading, isLoadingDocument else { return false }
        isLoadingDocument = false; phase = .ready; return true
    }
    mutating func fail(_ message: String) -> Bool {
        guard phase == .loading || phase == .ready else { return false }
        isLoadingDocument = false; phase = .failed(message); return true
    }
    mutating func close() { isLoadingDocument = false; phase = .closed }
}
