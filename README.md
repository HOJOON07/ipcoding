# 입코딩 하네스 (Claude Code)

입코딩 개발용 에이전트 팀 + 스킬 + CLAUDE.md 세트.

## 구성
```
CLAUDE.md                          # 프로젝트 헌법 (문서 체계, 규칙, 위임 규칙)
.claude/
├── agents/
│   ├── macos-api-researcher.md    # API 사실 조사 (읽기+웹)
│   ├── build-runner.md            # 빌드·테스트 실행 + 로그 요약 (Bash)
│   ├── code-reviewer.md           # diff 리뷰 (읽기 전용, macos-quirks 프리로드)
│   ├── spec-guardian.md           # 코드↔문서 정합 판정 (읽기 전용)
│   └── bench-analyst.md           # Phase 0 벤치 전담 (bench-protocol 프리로드)
└── skills/
    ├── macos-quirks/SKILL.md      # macOS API 함정 모음
    ├── ggml-integration/SKILL.md  # whisper.cpp / llama.cpp 통합 노하우
    └── bench-protocol/SKILL.md    # 측정 공식·판정 규칙
```

## 설치
1. 이 디렉토리 내용을 입코딩 리포 루트에 병합한다.
2. 제품 문서 4종을 `docs/`에 배치한다: PRD.md, TDD.md, PLAN.md, BENCH.md (CLAUDE.md가 이 경로를 참조).
3. Claude Code 세션을 (재)시작한다 — 에이전트 정의는 세션 시작 시 로드되므로, 파일 수정 후에는 재시작이 필요하다.
4. `/doctor`로 에이전트 이름 중복이 없는지 확인한다.

## 사용 예
- 자동 위임: description에 걸리면 Claude가 알아서 사용한다 (예: 빌드 요청 → build-runner).
- 명시 호출: "macos-api-researcher 서브에이전트로 CGEventTap 타임아웃 동작 조사해줘"
- 태스크 흐름 예: "태스크 1.7 진행해줘" → (구현) → "code-reviewer로 diff 리뷰" → "build-runner로 테스트" → 완료 기준 확인.
