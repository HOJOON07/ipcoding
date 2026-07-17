import CryptoKit
import Foundation

/// 다운로드 진행 상황 (온보딩·설정 진행률 표시용).
struct DownloadProgress: Sendable, Equatable {
    let received: Int64
    let total: Int64

    var fraction: Double {
        total > 0 ? Double(received) / Double(total) : 0
    }
}

/// 모델 파일 다운로드 엔진 (태스크 3.2, TDD §3.9).
///
/// 이어받기: `<filename>.partial`에 이어 쓴다 — 기존 크기를 offset으로 Range 요청.
/// resume data 방식과 달리 앱 재시작·크래시를 넘어서도 결정적으로 이어받는다.
/// 서버가 Range를 무시하면(200) 처음부터 다시 쓴다.
///
/// 무결성: 다운로드 완료 후 스트리밍 sha256을 검증하고, 통과했을 때만 최종 파일명으로
/// rename한다 — 최종 파일명이 존재하면 곧 "검증된 파일"이라는 불변식 유지.
/// 실패(불일치) 시 partial을 삭제하고 checksumMismatch를 던진다 (재다운로드 유도).
enum ModelDownloader {

    /// 진행 콜백은 ~0.25s 간격으로 스로틀되어 임의 스레드에서 호출된다.
    static func download(
        spec: ModelSpec,
        into directory: URL,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        let finalURL = directory.appendingPathComponent(spec.filename)
        let partialURL = directory.appendingPathComponent(spec.filename + ".partial")
        let fm = FileManager.default

        // 최종 파일 존재 = 검증 완료본 (불변식). 그대로 사용.
        if fm.fileExists(atPath: finalURL.path) {
            onProgress(DownloadProgress(received: spec.sizeBytes, total: spec.sizeBytes))
            return finalURL
        }

        var offset: Int64 = 0
        if let size = (try? fm.attributesOfItem(atPath: partialURL.path))?[.size] as? Int64 {
            offset = size
        } else {
            fm.createFile(atPath: partialURL.path, contents: nil)
        }
        if offset > spec.sizeBytes {
            // 기대 크기 초과 = 손상 partial — 버리고 처음부터.
            try? fm.removeItem(at: partialURL)
            fm.createFile(atPath: partialURL.path, contents: nil)
            offset = 0
        }

        if offset < spec.sizeBytes {
            try await fetch(spec: spec, to: partialURL, offset: offset, onProgress: onProgress)
        }

        // 크기·해시 검증 — 통과 시에만 최종 이름으로 승격.
        let finalSize = ((try? fm.attributesOfItem(atPath: partialURL.path))?[.size] as? Int64) ?? -1
        if finalSize < spec.sizeBytes {
            // 미완 전송(short read) — partial을 보존해 재시도에서 이어받는다 (리뷰 N2).
            throw ModelManagerError.downloadFailed(
                underlying: URLError(.networkConnectionLost)
            )
        }
        if finalSize > spec.sizeBytes {
            // 기대 초과 = 오염 — 폐기 후 재다운로드 필요.
            try? fm.removeItem(at: partialURL)
            throw ModelManagerError.checksumMismatch(spec: spec)
        }
        let digest = try await sha256(of: partialURL)
        guard digest == spec.sha256 else {
            try? fm.removeItem(at: partialURL)
            throw ModelManagerError.checksumMismatch(spec: spec)
        }
        try fm.moveItem(at: partialURL, to: finalURL)
        onProgress(DownloadProgress(received: spec.sizeBytes, total: spec.sizeBytes))
        return finalURL
    }

    // MARK: - 전송 (델리게이트 청크 쓰기 — 5GB급에서 바이트 단위 루프는 병목)

    private static func fetch(
        spec: ModelSpec,
        to partialURL: URL,
        offset: Int64,
        onProgress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        try Task.checkCancellation()  // 이미 취소된 채 진입하면 시작 자체를 하지 않는다 (리뷰 W2)
        guard let url = URL(string: spec.urlString) else {
            throw ModelManagerError.invalidURL(spec: spec)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60  // 요청/유휴 타임아웃 (전체 전송 시간 아님)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let writer = try ChunkFileWriter(
            partialURL: partialURL, offset: offset, total: spec.sizeBytes, onProgress: onProgress
        )
        let session = URLSession(configuration: .ephemeral, delegate: writer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writer.continuation = continuation
                writer.attach(session.dataTask(with: request))  // attach가 기취소 레이스 처리
            }
        } onCancel: {
            writer.cancel()  // partial은 남는다 — 다음 실행에서 이어받기
        }
    }

    /// URLSession 델리게이트 — 청크를 받는 즉시 partial 파일에 append.
    /// 파일·진행 상태는 URLSession 델리게이트 큐(직렬)에서만 접근되고, 취소 관련
    /// 상태(task/cancelled)만 lock으로 보호해 임의 스레드(onCancel)와 공유한다
    /// (@unchecked Sendable 근거 — 리뷰 W2).
    private final class ChunkFileWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let handle: FileHandle
        private let partialURL: URL
        private var received: Int64
        private let total: Int64
        private let onProgress: @Sendable (DownloadProgress) -> Void
        private var lastReport = Date.distantPast
        var continuation: CheckedContinuation<Void, Error>?

        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false

        init(partialURL: URL, offset: Int64, total: Int64,
             onProgress: @escaping @Sendable (DownloadProgress) -> Void) throws {
            self.handle = try FileHandle(forWritingTo: partialURL)
            self.partialURL = partialURL
            self.received = offset
            self.total = total
            self.onProgress = onProgress
            super.init()
            try handle.seekToEnd()
        }

        /// 태스크 등록 + 시작. attach 이전에 cancel()이 먼저 왔다면 즉시 취소한다
        /// — 취소가 no-op이 되어 대형 전송이 계속되는 레이스 차단 (리뷰 W2).
        func attach(_ task: URLSessionDataTask) {
            lock.lock()
            self.task = task
            let alreadyCancelled = cancelled
            lock.unlock()
            task.resume()
            if alreadyCancelled {
                task.cancel()
            }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                return
            }
            switch http.statusCode {
            case 206:
                completionHandler(.allow)
            case 200:
                // 서버가 Range를 무시하고 전체를 다시 보냄 — 처음부터 다시 쓴다.
                if received > 0 {
                    try? handle.truncate(atOffset: 0)
                    received = 0
                }
                completionHandler(.allow)
            case 416:
                // Range 불가(파일이 이미 온전할 때 등) — 성공으로 마감하고 크기·해시 검증에
                // 맡긴다. 마커 없이 .cancel하면 didComplete가 취소 에러로 실패시켜 같은
                // partial로 무한 416 루프가 된다 (리뷰 W1).
                dataTask.taskDescription = "complete416"
                completionHandler(.cancel)
            default:
                dataTask.taskDescription = "http\(http.statusCode)"  // 완료 콜백에서 상태 코드 전달
                completionHandler(.cancel)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                try handle.write(contentsOf: data)
            } catch {
                dataTask.taskDescription = "diskWriteFailed"
                dataTask.cancel()
                return
            }
            received += Int64(data.count)
            let now = Date()
            if now.timeIntervalSince(lastReport) > 0.25 {
                lastReport = now
                onProgress(DownloadProgress(received: received, total: total))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            try? handle.close()
            guard let continuation else { return }
            self.continuation = nil
            switch task.taskDescription {
            case "complete416":
                continuation.resume()  // 크기·해시 검증이 최종 판정 (리뷰 W1)
            case "diskWriteFailed":
                continuation.resume(throwing: ModelManagerError.diskWriteFailed)
            case let detail? where detail.hasPrefix("http"):
                continuation.resume(throwing: ModelManagerError.serverRejected(detail: detail))
            default:
                if let error {
                    // 취소 포함 — partial은 보존되어 다음 실행에서 이어받는다.
                    continuation.resume(throwing: ModelManagerError.downloadFailed(underlying: error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - 스트리밍 sha256 (CryptoKit — 5GB도 메모리 상수)

    static func sha256(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            await Task.yield()  // 협조 풀 장기 점유 방지 (5GB ≈ 수 초)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
