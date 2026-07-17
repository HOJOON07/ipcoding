import SwiftUI

/// 설정 화면 (태스크 3.3). 저장은 @AppStorage(UserDefaults), 적용은 onChange 클로저로
/// 앱에 통지 — 설정 값의 단일 정본은 UserDefaults, 런타임 반영은 IpCodingApp이 수행한다.
/// 주입 방식 항목은 UnicodeEventInjector와 함께 3.4에서 추가 (PLAN).
struct SettingsView: View {

    static let hotkeyComboKey = "hotkeyCombo"
    static let firstTokenTimeoutKey = "llmFirstTokenTimeoutMs"
    static let totalTimeoutKey = "llmTotalTimeoutMs"
    /// 빈 문자열 = 시스템 기본 입력 (TDD §3.2).
    static let inputDeviceUIDKey = "inputDeviceUID"
    static let inputDeviceNameKey = "inputDeviceName"
    static let injectionMethodKey = "injectionMethod"

    @AppStorage(SettingsView.hotkeyComboKey) private var hotkeyComboRaw = HotkeyCombo.commandFn.rawValue
    @AppStorage("autoInjectDelayMs") private var injectDelayMs = 500
    @AppStorage(SettingsView.firstTokenTimeoutKey) private var firstTokenTimeoutMs = 3000
    @AppStorage(SettingsView.totalTimeoutKey) private var totalTimeoutMs = 8000
    @AppStorage(SettingsView.inputDeviceUIDKey) private var inputDeviceUID = ""
    @AppStorage(SettingsView.inputDeviceNameKey) private var inputDeviceName = ""
    @AppStorage(SettingsView.injectionMethodKey) private var injectionMethodRaw = InjectionMethod.pasteboard.rawValue
    @State private var inputDevices: [AudioInputDevices.Device] = []

    // 모델 관리 (재다운로드 배선 — 3.2 리뷰 N3 이월)
    @State private var modelProgress: [String: DownloadProgress] = [:]
    @State private var busyModelId: String?
    @State private var modelNotice: String?
    @State private var confirmingRedownload: ModelSpec?
    @State private var confirmingDelete: ModelSpec?
    /// 삭제/재다운로드 후 행 상태 갱신 트리거 (isInstalled는 뷰 상태가 아니라서).
    @State private var modelRefresh = 0

    let modelManager: ModelManager
    let onHotkeyChange: (HotkeyCombo) -> Void
    let onInjectDelayChange: (Int) -> Void
    let onTimeoutChange: (_ firstTokenMs: Int, _ totalMs: Int) -> Void
    /// nil = 시스템 기본.
    let onInputDeviceChange: (String?) -> Void
    let onInjectionMethodChange: (InjectionMethod) -> Void

    var body: some View {
        Form {
            hotkeySection
            inputDeviceSection
            injectSection
            timeoutSection
            modelSection
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .onAppear { inputDevices = AudioInputDevices.enumerate() }
    }

    // MARK: - 입력 장치 (TDD §3.2 — UID 저장, 부재 시 시스템 기본 폴백)

    private var inputDeviceSection: some View {
        Section {
            Picker("마이크", selection: $inputDeviceUID) {
                Text("시스템 기본").tag("")
                ForEach(inputDevices) { device in
                    Text(device.name).tag(device.uid)
                }
                // 저장된 장치가 지금 미연결이면 목록에 없어도 선택 상태를 표현한다.
                if !inputDeviceUID.isEmpty, !inputDevices.contains(where: { $0.uid == inputDeviceUID }) {
                    Text("\(inputDeviceName.isEmpty ? "저장된 장치" : inputDeviceName) (미연결)")
                        .tag(inputDeviceUID)
                }
            }
            .onChange(of: inputDeviceUID) {
                inputDeviceName = inputDevices.first { $0.uid == inputDeviceUID }?.name ?? inputDeviceName
                onInputDeviceChange(inputDeviceUID.isEmpty ? nil : inputDeviceUID)
            }
        } header: {
            Text("입력 장치")
        } footer: {
            Text("선택한 장치가 연결돼 있지 않으면 시스템 기본 마이크를 사용해요 (다음 발화부터 적용)")
        }
    }

    // MARK: - 핫키 (TDD §3.1 프리셋)

    private var hotkeySection: some View {
        Section("핫키") {
            Picker("녹음 핫키 (누르는 동안 녹음)", selection: $hotkeyComboRaw) {
                ForEach(HotkeyCombo.allCases, id: \.rawValue) { combo in
                    Text(combo.displayName).tag(combo.rawValue)
                }
            }
            .onChange(of: hotkeyComboRaw) {
                if let combo = HotkeyCombo(rawValue: hotkeyComboRaw) {
                    onHotkeyChange(combo)
                }
            }
        }
    }

    // MARK: - 자동 주입 대기 N (메뉴와 같은 UserDefaults 키 공유 — 태스크 2.7)

    private var injectSection: some View {
        Section("주입") {
            Picker("자동 주입 대기", selection: $injectDelayMs) {
                Text("즉시 (Tab/Esc 창 없음)").tag(0)
                Text("0.5초").tag(500)
                Text("1.0초").tag(1000)
                Text("1.5초").tag(1500)
                Text("2.0초").tag(2000)
            }
            .onChange(of: injectDelayMs) { onInjectDelayChange(injectDelayMs) }
            // 주입 방식 (태스크 3.4, TDD §3.7 — 유니코드는 클립보드 미사용 대신 다소 느림)
            Picker("주입 방식", selection: $injectionMethodRaw) {
                ForEach(InjectionMethod.allCases, id: \.rawValue) { method in
                    Text(method.displayName).tag(method.rawValue)
                }
            }
            .onChange(of: injectionMethodRaw) {
                if let method = InjectionMethod(rawValue: injectionMethodRaw) {
                    onInjectionMethodChange(method)
                }
            }
        }
    }

    // MARK: - LLM 타임아웃 (TDD §3.4 — 초과 시 원문 폴백)

    private var timeoutSection: some View {
        Section {
            Picker("첫 토큰 대기", selection: $firstTokenTimeoutMs) {
                Text("2초").tag(2000)
                Text("3초 (기본)").tag(3000)
                Text("5초").tag(5000)
            }
            Picker("전체 교정 제한", selection: $totalTimeoutMs) {
                Text("5초").tag(5000)
                Text("8초 (기본)").tag(8000)
                Text("12초").tag(12000)
            }
        } header: {
            Text("교정 타임아웃")
        } footer: {
            Text("초과하면 교정 없이 원문을 사용해요 (다음 발화부터 적용)")
        }
        .onChange(of: firstTokenTimeoutMs) { onTimeoutChange(firstTokenTimeoutMs, totalTimeoutMs) }
        .onChange(of: totalTimeoutMs) { onTimeoutChange(firstTokenTimeoutMs, totalTimeoutMs) }
    }

    // MARK: - 모델 관리 (TDD §3.9 — 재다운로드·삭제)

    private var modelSection: some View {
        Section {
            ForEach(ModelManager.requiredModels, id: \.id) { spec in
                modelRow(spec)
            }
            if let modelNotice {
                Text(modelNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("AI 모델")
        } footer: {
            Text("재다운로드·삭제 후 교체된 모델은 앱을 다시 실행해야 적용돼요")
        }
        .alert("모델을 다시 받을까요?", isPresented: redownloadAlertBinding, presenting: confirmingRedownload) { spec in
            Button("다시 받기 (\(spec.sizeBytes.formatted(.byteCount(style: .file))))") {
                startRedownload(spec)
            }
            Button("취소", role: .cancel) {}
        } message: { spec in
            Text("\(spec.displayName)을 지우고 처음부터 다시 다운로드해요.")
        }
        .alert("모델을 삭제할까요?", isPresented: deleteAlertBinding, presenting: confirmingDelete) { spec in
            Button("삭제", role: .destructive) { deleteModel(spec) }
            Button("취소", role: .cancel) {}
        } message: { spec in
            Text("\(spec.displayName)을 디스크에서 지워요. 다음 실행 시 온보딩에서 다시 받아요.")
        }
    }

    private func modelRow(_ spec: ModelSpec) -> some View {
        let installed = modelManager.isInstalled(spec)
        let isBusy = busyModelId == spec.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.displayName)
                    Text(installed
                         ? "설치됨 · \(spec.sizeBytes.formatted(.byteCount(style: .file)))"
                         : "없음 — 다음 실행 시 온보딩에서 다운로드")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("다시 받기") { confirmingRedownload = spec }
                    .disabled(busyModelId != nil)
                Button("삭제", role: .destructive) { confirmingDelete = spec }
                    .disabled(busyModelId != nil || !installed)
            }
            if isBusy {
                ProgressView(value: modelProgress[spec.id]?.fraction ?? 0)
            }
        }
        .id("\(spec.id)-\(modelRefresh)")
    }

    private var redownloadAlertBinding: Binding<Bool> {
        Binding(get: { confirmingRedownload != nil }, set: { if !$0 { confirmingRedownload = nil } })
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } })
    }

    private func startRedownload(_ spec: ModelSpec) {
        guard busyModelId == nil else { return }
        busyModelId = spec.id
        modelNotice = nil
        Task {
            defer {
                busyModelId = nil
                modelRefresh += 1
            }
            do {
                try await modelManager.redownload(spec) { progress in
                    modelProgress[spec.id] = progress
                }
                modelNotice = "\(spec.displayName) 재다운로드·검증 완료 — 앱 재시작 후 적용돼요"
            } catch ModelManagerError.anotherDownloadActive {
                modelNotice = "다른 다운로드가 진행 중이에요 — 완료 후 다시 시도해주세요"
            } catch {
                if !Task.isCancelled {
                    modelNotice = "재다운로드 실패 — 네트워크·디스크 확인 후 다시 시도해주세요"
                }
            }
        }
    }

    private func deleteModel(_ spec: ModelSpec) {
        let fm = FileManager.default
        try? fm.removeItem(at: modelManager.modelsDirectory.appendingPathComponent(spec.filename))
        // 중단된 재다운로드의 .partial 잔재도 함께 정리 (리뷰 N1 — GB 단위 잔존 방지).
        try? fm.removeItem(at: modelManager.modelsDirectory.appendingPathComponent(spec.filename + ".partial"))
        modelNotice = "\(spec.displayName) 삭제됨 — 다음 실행 시 온보딩에서 다시 받아요"
        modelRefresh += 1
    }
}
