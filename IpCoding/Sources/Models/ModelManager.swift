import Foundation
import os

/// 모델 종류 (TDD §3.9 kind).
enum ModelKind: String {
    case stt
    case llm
}

/// 모델 메타. Phase 1은 다운로드 없이 수동 배치 파일만 참조하므로 url/sha256은 Phase 3에서 채운다.
struct ModelSpec {
    let id: String
    let displayName: String
    let filename: String
    let kind: ModelKind
}

enum ModelManagerError: Error {
    /// 모델 파일이 배치 경로에 없음. Phase 1은 수동 배치 — 사용자가 직접 넣어야 함 (다운로드는 Phase 3).
    case fileMissing(spec: ModelSpec, expectedPath: URL)
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
        kind: .stt
    )

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
}
