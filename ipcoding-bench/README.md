# ipcoding-bench — Phase 0 벤치마크

정본 명세: `../docs/BENCH.md`. 측정 규칙: `.claude/skills/bench-protocol`.

## 준비

```sh
source .venv/bin/activate   # 또는 .venv/bin/python으로 직접 실행
```

모델은 `models/`에 있어야 한다 (ggml-large-v3-turbo-q5_0.bin, ggml-medium-q5_0.bin).

## 실행 순서

1. **녹음** — 대본 30문장을 에어팟으로 녹음 (`audio/s01.wav` ~ `s30.wav`):
   ```sh
   python record.py              # 미녹음 문장만
   python record.py --redo s07   # 특정 문장 재녹음
   ```
2. **실험 A (STT)**:
   ```sh
   python bench_stt.py           # → results_stt.csv
   python bench_stt.py --rtf-reps 3   # 빠른 시험용 (정식 측정은 기본 10회)
   ```
3. **시드 사전 작성** — results_stt.csv의 오인식 패턴에서 `dictionary_seed.json` 작성:
   ```json
   [{"spoken": "유즈 스테이트", "written": "useState"}]
   ```
4. **실험 B (LLM)** — Ollama 후보를 pull한 뒤 (디스크 여유 확인):
   ```sh
   python bench_llm.py --models <태그1> <태그2> ...   # → results_llm.csv
   ```
   후보 4종: qwen3.5 4B / qwen3.5 9B / kanana 1.5 8B / gemma4 e4b — 실제 태그는 실행 시점에 지정.
5. results_llm.csv의 수동 채점 컬럼(교정성공·의도보존·정돈품질·비고)을 채우고 REPORT.md 작성.

## TODO

- **Apple SFSpeechRecognizer 기준선**: Swift 헬퍼 바이너리가 필요해 bench_stt.py 범위 밖.
  별도 헬퍼(`SFSpeechURLRecognitionRequest`로 wav 파일 전사)를 만들어 동일 CSV 스키마로 병합할 것.
