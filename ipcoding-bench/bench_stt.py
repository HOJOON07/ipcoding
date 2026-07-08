#!/usr/bin/env python3.11
"""bench_stt.py — 실험 A: whisper.cpp 후보 모델 × 30문장 전사 벤치.

사용법:
    .venv/bin/python bench_stt.py
    .venv/bin/python bench_stt.py --models models/ggml-large-v3-turbo-q5_0.bin
    .venv/bin/python bench_stt.py --rtf-reps 3   # RTF 반복 횟수 축소 (빠른 시험용)

조건:
- language=ko 고정, no timestamps.
- 파일명에 "turbo"가 포함된 모델만 initial_prompt 유무 2조건 측정
  (프롬프트 = sentences.json 전체 terms를 콤마로 이은 문자열).

지표 (docs/BENCH.md §3):
- CER: jiwer.cer, 정규화 = 연속 공백→1개·앞뒤 공백 제거·문장부호 유지. 유형 A~D만.
- 용어 적중률: terms 정확 문자열 포함 (대소문자 구분).
- RTF: 처리시간/오디오길이. 파일별 --rtf-reps회 반복, 첫 회 워밍업 제외 후 중앙값.

출력: results_stt.csv + 콘솔 요약표.

TODO: Apple SFSpeechRecognizer 기준선은 Swift 헬퍼 필요 — 이 스크립트 범위 밖 (README 참조).
"""

import argparse
import csv
import json
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

import jiwer
import soundfile as sf

BENCH_DIR = Path(__file__).resolve().parent
WHISPER_CLI = "/opt/homebrew/bin/whisper-cli"
DEFAULT_MODELS = [
    "models/ggml-large-v3-turbo-q5_0.bin",
    "models/ggml-medium-q5_0.bin",
]


def normalize(text: str) -> str:
    """공백 정규화: 연속 공백→1개, 앞뒤 제거. 문장부호는 유지."""
    return re.sub(r"\s+", " ", text).strip()


def load_sentences():
    with open(BENCH_DIR / "sentences.json", encoding="utf-8") as f:
        return json.load(f)


def build_initial_prompt(sentences) -> str:
    terms = []
    for s in sentences:
        for t in s["terms"]:
            if t not in terms:
                terms.append(t)
    return ", ".join(terms)


def transcribe(model_path: Path, wav_path: Path, prompt: str | None) -> tuple[str, float]:
    """1회 전사. (전사문, 처리시간 초) 반환. 처리시간은 프로세스 전체 벽시계."""
    cmd = [WHISPER_CLI, "-m", str(model_path), "-f", str(wav_path),
           "-l", "ko", "-nt", "-np"]
    if prompt:
        cmd += ["--prompt", prompt]
    t0 = time.perf_counter()
    proc = subprocess.run(cmd, capture_output=True, text=True)
    elapsed = time.perf_counter() - t0
    if proc.returncode != 0:
        print(f"whisper-cli 실패 ({wav_path.name}):\n{proc.stderr[-2000:]}", file=sys.stderr)
        sys.exit(1)
    return normalize(proc.stdout), elapsed


def audio_duration(wav_path: Path) -> float:
    info = sf.info(str(wav_path))
    return info.frames / info.samplerate


def run_condition(model_path: Path, condition: str, prompt: str | None,
                  sentences, rtf_reps: int):
    rows = []
    for s in sentences:
        wav = BENCH_DIR / "audio" / f"{s['id']}.wav"
        if not wav.exists():
            print(f"  {s['id']}: audio 없음 — 건너뜀", file=sys.stderr)
            continue
        dur = audio_duration(wav)

        # 반복 측정: 첫 회 = 워밍업(RTF 제외), 전사문은 첫 회 결과 사용
        times = []
        transcript = None
        for i in range(max(rtf_reps, 2)):
            text, elapsed = transcribe(model_path, wav, prompt)
            if i == 0:
                transcript = text
            else:
                times.append(elapsed)
        rtf = statistics.median(times) / dur

        # CER: 유형 A~D만 (E는 축어 정답 없음)
        if s["type"] == "E":
            cer = ""
        else:
            cer = jiwer.cer(normalize(s["text"]), transcript)

        hits = sum(1 for t in s["terms"] if t in transcript)
        total = len(s["terms"])

        rows.append({
            "model": model_path.name,
            "condition": condition,
            "sentence_id": s["id"],
            "type": s["type"],
            "transcript": transcript,
            "cer": f"{cer:.4f}" if cer != "" else "",
            "terms_hit": hits,
            "terms_total": total,
            "rtf": f"{rtf:.4f}",
        })
        cer_str = f"cer={cer:.3f}" if cer != "" else "cer=—(E)"
        print(f"  {s['id']} [{s['type']}] {cer_str} terms={hits}/{total} rtf={rtf:.3f}  | {transcript}")
    return rows


def summarize(rows):
    groups = {}
    for r in rows:
        groups.setdefault((r["model"], r["condition"]), []).append(r)
    print("\n===== 요약 =====")
    header = f"{'모델':<32} {'조건':<10} {'평균CER(A-D)':>12} {'용어적중률':>10} {'RTF중앙값':>10}"
    print(header)
    print("-" * len(header))
    for (model, cond), rs in groups.items():
        cers = [float(r["cer"]) for r in rs if r["cer"] != ""]
        mean_cer = sum(cers) / len(cers) if cers else float("nan")
        hit = sum(r["terms_hit"] for r in rs)
        tot = sum(r["terms_total"] for r in rs)
        hit_rate = hit / tot if tot else float("nan")
        med_rtf = statistics.median(float(r["rtf"]) for r in rs)
        print(f"{model:<32} {cond:<10} {mean_cer:>12.4f} {hit_rate:>9.1%} {med_rtf:>10.3f}")
    print("\n판정 순서 (BENCH.md §3): 용어 적중률 → CER → RTF. 비등하면 turbo.")


def main():
    parser = argparse.ArgumentParser(description="실험 A: STT 벤치")
    parser.add_argument("--models", nargs="+", default=DEFAULT_MODELS,
                        help="whisper 모델 파일 경로 목록")
    parser.add_argument("--rtf-reps", type=int, default=10,
                        help="파일별 반복 횟수 (첫 회는 워밍업으로 RTF에서 제외, 기본 10)")
    args = parser.parse_args()

    sentences = load_sentences()
    initial_prompt = build_initial_prompt(sentences)
    print(f"initial_prompt ({len(initial_prompt)}자): {initial_prompt}\n")

    missing = [s["id"] for s in sentences
               if not (BENCH_DIR / "audio" / f"{s['id']}.wav").exists()]
    if missing:
        print(f"경고: 오디오 미존재 {len(missing)}개: {', '.join(missing)}\n", file=sys.stderr)

    all_rows = []
    for m in args.models:
        model_path = (BENCH_DIR / m) if not Path(m).is_absolute() else Path(m)
        if not model_path.exists():
            print(f"모델 파일 없음: {model_path}", file=sys.stderr)
            sys.exit(1)

        conditions = [("no_prompt", None)]
        if "turbo" in model_path.name:
            conditions.append(("with_prompt", initial_prompt))

        for cond_name, prompt in conditions:
            print(f"\n### {model_path.name} / {cond_name}")
            all_rows += run_condition(model_path, cond_name, prompt, sentences, args.rtf_reps)

    out = BENCH_DIR / "results_stt.csv"
    with open(out, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "model", "condition", "sentence_id", "type", "transcript",
            "cer", "terms_hit", "terms_total", "rtf"])
        writer.writeheader()
        writer.writerows(all_rows)
    print(f"\n저장: {out}")

    summarize(all_rows)


if __name__ == "__main__":
    main()
