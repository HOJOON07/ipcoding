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
- 통합 선택지: ① C API 직접 브릿징(모듈맵 + 헤더) ② xcframework 빌드 후 링크. whisper는 ②로 통합함(Vendor/whisper.xcframework). llama도 ②이되 whisper와 ggml을 공유해야 함(아래 알려진 이슈).
- 로드: gguf 파일 → `llama_model_load_from_file` → 컨텍스트 생성. 상주. n_ctx는 2048이면 충분(짧은 발화 교정).
- 샘플링(TDD 확정값): temperature=0.2, top_p=0.9, repeat_penalty=1.05. max_tokens = min(1024, 입력토큰×2). 정지 토큰 `<|im_end|>`(EOG) 지정.
- 스트리밍: 디코드 루프에서 토큰마다 콜백 → `Task { @MainActor in ... }`로 HUD에 전달. 루프 각 반복에서 취소 플래그(atomic) 체크 — Esc 취소의 반응성이 여기서 결정된다.
- 채팅 템플릿: Qwen은 ChatML(`<|im_start|>`). gguf 메타데이터 템플릿 또는 `llama_chat_apply_template`. RefineEngine은 C API로 직접 조립(TDD §3.5).
- **씽킹 억제(2.1 확정)**: Qwen3.5는 기본(reasoning auto)에서 `<think>` 블록을 출력에 누출해 품질이 붕괴한다. ChatML assistant 프리픽스에 빈 `<think>\n\n</think>` 시드를 넣어 즉시 답 생성(CLI로는 `--jinja --reasoning off`). 방어용으로 마지막 `</think>` 뒤 텍스트만 취하는 파싱 유지.
- **프롬프트 캐시(2.1 성능)**: v2 고정 프리픽스(~530토큰)가 TTFT의 대부분. 프리픽스 KV를 로드 시 1회 디코드·상주시키고 raw_text 델타만 프리필 → 총지연 1506ms→211ms (TDD §3.4).

## 알려진 이슈
- **ggml 중복 심볼(2.1 확정 리스크)**: whisper.cpp·llama.cpp를 각자 ggml 정적 포함한 xcframework로 함께 링크하면 중복 심볼 수백 개로 링크 실패. 둘을 동일 ggml 커밋으로 공유 빌드(단일 ggml 링크)해야 한다. 2.2 통합 방식으로 확정.
- **Ollama 블롭 비호환(2.1 확정)**: Ollama가 저장한 gguf 블롭은 자체 포크 기준이라 mainline llama.cpp에서 `qwen35.rope.dimension_sections` 스키마 불일치로 로드 실패. HuggingFace의 mainline 호환 gguf(unsloth/Qwen3.5-9B-GGUF 등)를 받아 쓸 것. llama.cpp도 최신 master(qwen35 arch 지원)로 빌드.
- Qwen3.5는 멀티모달이나 텍스트/비전 gguf가 **별도 배포** — 텍스트 gguf만 받으면 mmproj 없이 순수 텍스트 로드·생성 가능(2.1 확인, blocker 아님).
- 모델 파일 경로: `~/Library/Application Support/IpCoding/models/`. 리포에 커밋 금지.
- 메모리: 로드 실패의 흔한 원인은 파일 손상(다운로드 중단) — sha256 검증 후 로드.

## 검증 커맨드 (스파이크용)
- whisper CLI: `./main -m ggml-large-v3-turbo-q5_0.bin -l ko -f sample.wav`
- llama CLI: `./llama-cli -m model.gguf -p "..." -n 128 --temp 0.2`
- Swift 통합 전에 CLI로 모델·파라미터가 기대 품질을 내는지 먼저 확인하면 디버깅 변수가 절반이 된다.
