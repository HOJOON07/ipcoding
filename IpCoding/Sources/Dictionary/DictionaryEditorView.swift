import SwiftUI

/// 편집 화면의 행. 표시 순서를 안정적으로 유지하기 위해 별도 id를 갖는다
/// (DictionaryEntry는 값 쌍뿐이라 중복 행을 구분할 수 없다).
private struct EditorRow: Identifiable, Equatable {
    let id = UUID()
    var spoken: String
    var written: String
}

/// 사전 편집 테이블 (태스크 2.8, TDD §3.6 / PRD "사전 편집은 가볍게").
/// "들리는 대로(오인식) → 원하는 표기" 쌍의 CRUD. 변경은 자동 저장된다 — 별도 저장 버튼 없음.
/// 저장 안전장치 2겹 (진행 중 세션의 치환이 편집 중간 상태를 읽는 사고 축소):
///   ① 빈 칸이 남은 행은 저장에서 제외 (신규 행 커버)
///   ② 0.5s 디바운스 — 기존 행 수정 중의 잘린 문자열(예: "유즈 스테이트"를 지우다 남은
///      "유즈")이 키 입력 단위로 사전에 반영되는 창을 줄인다. 타이핑을 0.5s 멈춘 시점의
///      중간 상태는 여전히 저장될 수 있다 — 완전 차단이 아니라 축소.
struct DictionaryEditorView: View {

    @State private var rows: [EditorRow]
    @State private var selection = Set<EditorRow.ID>()
    @State private var saveTask: Task<Void, Never>?
    /// 마지막으로 저장한(또는 초기 로드된) 항목 — 내용이 같으면 재저장하지 않는다.
    @State private var lastSaved: [DictionaryEntry]
    private let onSave: ([DictionaryEntry]) -> Void

    init(entries: [DictionaryEntry], onSave: @escaping ([DictionaryEntry]) -> Void) {
        _rows = State(initialValue: entries.map { EditorRow(spoken: $0.spoken, written: $0.written) })
        _lastSaved = State(initialValue: entries)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Table($rows, selection: $selection) {
                TableColumn("들리는 대로 (오인식)") { $row in
                    TextField("예: 유지 스테이트", text: $row.spoken)
                }
                TableColumn("원하는 표기") { $row in
                    TextField("예: useState", text: $row.written)
                }
            }
            .onChange(of: rows) { scheduleSave() }
            .onDeleteCommand { removeSelection() }

            Divider()
            footer
        }
        .frame(minWidth: 440, minHeight: 320)
        .onDisappear { flushSave() }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: addRow) {
                Image(systemName: "plus")
            }
            .help("항목 추가")
            Button(action: removeSelection) {
                Image(systemName: "minus")
            }
            .disabled(selection.isEmpty)
            .help("선택 항목 삭제")

            Spacer()

            if hasDuplicateSpoken {
                Text("중복된 '들리는 대로'가 있어요 — 하나만 적용됩니다")
                    .foregroundStyle(.orange)
            }
            Text("\(completeEntries.count)개 항목 · 변경 즉시 저장")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(10)
    }

    private func addRow() {
        rows.append(EditorRow(spoken: "", written: ""))
    }

    private func removeSelection() {
        rows.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    /// 양쪽이 채워진 행만 트림해 항목화 — 빈 행은 편집 화면에만 남는다.
    private var completeEntries: [DictionaryEntry] {
        rows.compactMap { row in
            let spoken = row.spoken.trimmingCharacters(in: .whitespaces)
            let written = row.written.trimmingCharacters(in: .whitespaces)
            guard !spoken.isEmpty, !written.isEmpty else { return nil }
            return DictionaryEntry(spoken: spoken, written: written)
        }
    }

    private var hasDuplicateSpoken: Bool {
        let spokens = completeEntries.map(\.spoken)
        return Set(spokens).count != spokens.count
    }

    /// 디바운스 저장 — 타이핑이 0.5s 멎으면 저장. 새 변경이 오면 이전 예약을 취소.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return  // 취소됨 — 더 새로운 변경이 예약을 대체
            }
            save()
        }
    }

    /// 뷰 소멸 시 예약을 즉시 확정 (디바운스 대기분 유실 방지).
    private func flushSave() {
        saveTask?.cancel()
        save()
    }

    private func save() {
        let entries = completeEntries
        guard entries != lastSaved else { return }
        lastSaved = entries
        onSave(entries)
    }
}
