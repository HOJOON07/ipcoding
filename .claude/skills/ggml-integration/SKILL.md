---
name: ggml-integration
description: whisper.cpp와 llama.cpp를 Swift 앱에 통합하는 절차와 파라미터. TranscribeEngine/RefineEngine 구현, 모델 로드, 스트리밍 콜백, 취소, gguf 관련 작업 시 참조.
---

# whisper.cpp / llama.cpp 통합 (입코딩)

둘 다 ggml 기반 C 라이브러리. Swift에서 C API를 직접 호출한다. TDD §3.3, §3.4가 파라미터 정본.

## whisper.cpp
- 통합: 공식 SwiftPM 패키지 지원 — Xcode에 패키지 의존성으로 추가. Metal은 Apple Silicon에서 기본 활성.
- 초기화: `whisper_init_from_file_with_params` — 앱 시작 시 1회, 컨텍스트 상주. 스레드 안전하지 않으므로 전용 직렬 큐에서만 접근.
- 전사 파라미터(TDD 확정값): language="ko", translate=false, no_timestamps=true, greedy(속도) — Phase 0에서 beam과 비교 후 확정. `initial_prompt`에 사전 용어 주입.
- 워밍업: 로드 직후 0.5초 무음 1회 추론 (첫 발화 지연 제거).
- 입력: 16kHz mono Float32 배열. 다른 포맷을 넣으면 조용히 쓰레기 결과가 나온다 — 포맷 검증 assert 권장.

## llama.cpp
- 통합 선택지: ① C API 직접 브릿징(모듈맵 + 헤더) ② xcframework 빌드 후 링크. 스파이크(태스크 2.1)에서 결정.
- 로드: gguf 파일 → `llama_model_load_from_file` → 컨텍스트 생성. 상주. n_ctx는 2048이면 충분(짧은 발화 교정).
- 샘플링(TDD 확정값): temperature=0.2, top_p=0.9, repeat_penalty=1.05. max_tokens = min(1024, 입력토큰×2).
- 스트리밍: 디코드 루프에서 토큰마다 콜백 → `Task { @MainActor in ... }`로 HUD에 전달. 루프 각 반복에서 취소 플래그(atomic) 체크 — Esc 취소의 반응성이 여기서 결정된다.
- 채팅 템플릿: 모델별로 다르다(Qwen은 ChatML 계열). gguf 메타데이터의 템플릿을 사용하거나 llama.cpp의 `llama_chat_apply_template` 활용 — 템플릿 불일치는 품질 저하의 흔한 원인.
- 씽킹 모드 지원 모델(Qwen3.5 등)은 비활성이 기본인지 확인하고, `<think>` 블록이 출력에 섞이면 파싱해 제거.

## 알려진 이슈
- Qwen3.5 Small 계열은 멀티모달이라 서드파티 gguf에 비전 파일(mmproj) 분리 이슈 보고 있음 — llama.cpp 직접 통합 시 텍스트 전용 로드가 되는지 태스크 2.1 스파이크에서 최우선 검증. 안 되면 후보 차순위 모델로 전환.
- 모델 파일 경로: `~/Library/Application Support/IpCoding/models/`. 리포에 커밋 금지.
- 메모리: 로드 실패의 흔한 원인은 파일 손상(다운로드 중단) — sha256 검증 후 로드.

## 검증 커맨드 (스파이크용)
- whisper CLI: `./main -m ggml-large-v3-turbo-q5_0.bin -l ko -f sample.wav`
- llama CLI: `./llama-cli -m model.gguf -p "..." -n 128 --temp 0.2`
- Swift 통합 전에 CLI로 모델·파라미터가 기대 품질을 내는지 먼저 확인하면 디버깅 변수가 절반이 된다.
