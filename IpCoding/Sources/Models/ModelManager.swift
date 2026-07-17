import Foundation
import os

/// 모델 종류 (TDD §3.9 kind).
enum ModelKind: String {
    case stt
    case llm
}

/// 모델 메타 (TDD §3.9 — 하드코딩 목록). 모델 업그레이드는 앱 릴리스에 태운다:
/// 버전별 스펙 고정 → 릴리스 업데이트 → 새 모델 다운로드·검증 (PLAN 3.2, 2026-07-13 결정).
struct ModelSpec: Sendable {
    let id: String
    let displayName: String
    let filename: String
    let kind: ModelKind
    /// 다운로드 URL 문자열 — URL 변환은 다운로더가 guard로 수행 (강제 언래핑 금지 규칙).
    let urlString: String
    /// 다운로드 무결성 검증용. 로컬 검증 파일(업스트림과 크기 일치 확인, 2026-07-17)에서 채취.
    let sha256: String
    let sizeBytes: Int64
}

enum ModelManagerError: Error {
    /// 모델 파일이 배치 경로에 없음 (다운로드 전).
    case fileMissing(spec: ModelSpec, expectedPath: URL)
    /// 스펙의 URL 문자열이 URL로 변환 불가 (하드코딩 오류).
    case invalidURL(spec: ModelSpec)
    /// 네트워크·전송 실패 (취소·미완 전송 포함) — partial 보존, 재시도 시 이어받기.
    case downloadFailed(underlying: Error)
    /// 서버가 요청을 거부 (HTTP 오류).
    case serverRejected(detail: String)
    /// 디스크 쓰기 실패 (공간 부족 등) — partial 보존.
    case diskWriteFailed
    /// sha256(또는 초과 크기) 불일치 — 파일 폐기됨, 재다운로드 필요 (TDD §3.9).
    case checksumMismatch(spec: ModelSpec)
}

/// 모델 파일의 경로 해석·존재 확인 (TDD §3.9의 Phase 1 최소 구현).
/// 다운로드·sha256 검증·진행률·재다운로드는 태스크 3.2에서 추가한다.
@MainActor
final class ModelManager {

    /// Phase 0에서 확정한 STT 모델 (REPORT.md: large-v3-turbo q5 + initial_prompt).
    static let whisperTurbo = ModelSpec(
        id: "whisper-large-v3-turbo-q5",
        displayName: "Whisper large-v3-turbo (q5)",
        filename: "ggml-large-v3-turbo-q5_0.bin",
        kind: .stt,
        urlString: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin",
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
        sizeBytes: 574_041_195
    )

    /// Phase 0에서 확정한 교정 LLM (REPORT.md: Qwen3.5 9B + 프롬프트 v2).
    /// gguf는 unsloth/Qwen3.5-9B-GGUF Q4_K_M (mainline llama.cpp 호환, 2.1 스파이크).
    static let qwenRefine = ModelSpec(
        id: "qwen3.5-9b-q4",
        displayName: "Qwen3.5 9B (Q4_K_M)",
        filename: "Qwen3.5-9B-Q4_K_M.gguf",
        kind: .llm,
        urlString: "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf",
        sha256: "03b74727a860a56338e042c4420bb3f04b2fec5734175f4cb9fa853daf52b7e8",
        sizeBytes: 5_680_522_464
    )

    /// 앱이 요구하는 전체 모델 (온보딩 다운로드 순서 — 작은 것 먼저).
    static let requiredModels = [whisperTurbo, qwenRefine]

    private let logger = Logger(subsystem: "com.hojoon.ipcoding", category: "models")

    /// `~/Library/Application Support/IpCoding/models/` (TDD §1, ggml-integration 스킬).
    let modelsDirectory: URL

    init() {
        // Application Support는 모든 사용자 세션에 존재하지만, 만약을 대비해 홈 기준으로 폴백.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        modelsDirectory = appSupport
            .appendingPathComponent("IpCoding", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    /// 모델 디렉토리를 보장(생성). 앱 시작 시 1회.
    func ensureModelsDirectory() throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    /// 배치된 모델 파일 경로를 반환. 없으면 fileMissing (Phase 1: 다운로드 없음).
    func resolvedPath(for spec: ModelSpec) throws -> URL {
        let path = modelsDirectory.appendingPathComponent(spec.filename)
        guard FileManager.default.fileExists(atPath: path.path) else {
            logger.error("모델 파일 없음: \(spec.filename, privacy: .public) @ \(self.modelsDirectory.path, privacy: .public)")
            throw ModelManagerError.fileMissing(spec: spec, expectedPath: path)
        }
        return path
    }

    /// 존재 여부만 (온보딩·설정 표시용).
    func isInstalled(_ spec: ModelSpec) -> Bool {
        let path = modelsDirectory.appendingPathComponent(spec.filename)
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// 전체 필수 모델 설치 여부 (온보딩 표시 조건).
    var allModelsInstalled: Bool {
        Self.requiredModels.allSatisfy { isInstalled($0) }
    }

    /// 다운로드 + sha256 검증 (태스크 3.2, TDD §3.9). 이미 설치돼 있으면 즉시 반환.
    /// 취소·실패 시 partial이 보존되어 재시도에서 이어받는다. 진행 콜백은 MainActor로 홉.
    func download(
        _ spec: ModelSpec,
        onProgress: @escaping @MainActor @Sendable (DownloadProgress) -> Void
    ) async throws {
        try ensureModelsDirectory()
        logger.info("모델 다운로드 시작: \(spec.id, privacy: .public)")
        _ = try await ModelDownloader.download(spec: spec, into: modelsDirectory) { progress in
            Task { @MainActor in onProgress(progress) }
        }
        logger.info("모델 다운로드·검증 완료: \(spec.id, privacy: .public)")
    }

    /// 손상 파일 재다운로드 (TDD §3.9 "로드 실패/파일 손상 시 재다운로드 유도"):
    /// 기존 파일·partial을 지우고 처음부터 받는다.
    func redownload(
        _ spec: ModelSpec,
        onProgress: @escaping @MainActor @Sendable (DownloadProgress) -> Void
    ) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: modelsDirectory.appendingPathComponent(spec.filename))
        try? fm.removeItem(at: modelsDirectory.appendingPathComponent(spec.filename + ".partial"))
        try await download(spec, onProgress: onProgress)
    }
}
