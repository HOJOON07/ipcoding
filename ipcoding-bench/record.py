#!/usr/bin/env python3.11
"""record.py — 대본을 한 문장씩 띄우고 녹음을 보조한다.

사용법:
    .venv/bin/python record.py              # 미녹음 문장만 순서대로
    .venv/bin/python record.py --redo s07   # 특정 문장 재녹음 (여러 개 가능)

audio/s01.wav ~ s30.wav 로 저장 (16kHz mono int16).
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import sounddevice as sd
import soundfile as sf

BENCH_DIR = Path(__file__).resolve().parent
AUDIO_DIR = BENCH_DIR / "audio"
SAMPLE_RATE = 16000


def load_sentences():
    with open(BENCH_DIR / "sentences.json", encoding="utf-8") as f:
        return json.load(f)


def show_sentence(s):
    print("\n" + "=" * 60)
    print(f"[{s['id']}] 유형 {s['type']}")
    if s["type"] == "E":
        print(f"  의도: {s['intent']}")
        print("  체크리스트 (모두 담아 즉흥으로 말하세요, 대본 없음):")
        for item in s["checklist"]:
            print(f"    - {item}")
        print("  ※ 길고 두서없어도 됩니다. 위 항목이 다 들어가게만.")
    else:
        print(f"  대본: {s['text']}")
    print("=" * 60)


def record_once():
    chunks = []

    def callback(indata, frames, time_info, status):
        if status:
            print(f"  (오디오 상태: {status})", file=sys.stderr)
        chunks.append(indata.copy())

    input("Enter를 누르면 녹음 시작...")
    stream = sd.InputStream(
        samplerate=SAMPLE_RATE, channels=1, dtype="int16", callback=callback
    )
    with stream:
        print("● 녹음 중... (Enter로 종료)")
        input()
    if not chunks:
        return np.zeros((0, 1), dtype=np.int16)
    return np.concatenate(chunks, axis=0)


def record_sentence(s, wav_path):
    show_sentence(s)
    while True:
        data = record_once()
        dur = len(data) / SAMPLE_RATE
        print(f"녹음 길이: {dur:.1f}초")
        if dur < 0.3:
            print("너무 짧습니다. 다시 녹음합니다.")
            continue
        sf.write(wav_path, data, SAMPLE_RATE, subtype="PCM_16")
        while True:
            cmd = input("(r)재녹음 / (p)재생 / (Enter)다음 / (q)종료 > ").strip().lower()
            if cmd == "r":
                break  # 바깥 루프에서 재녹음
            if cmd == "p":
                sd.play(data, SAMPLE_RATE)
                sd.wait()
                continue
            if cmd == "q":
                print("종료합니다. 지금까지 녹음은 저장됨.")
                sys.exit(0)
            if cmd == "":
                return
            print("r / p / q / Enter 중 하나를 입력하세요.")


def main():
    parser = argparse.ArgumentParser(description="벤치 대본 녹음 보조")
    parser.add_argument("--redo", nargs="+", metavar="ID",
                        help="재녹음할 문장 id (예: --redo s07 s12)")
    args = parser.parse_args()

    AUDIO_DIR.mkdir(exist_ok=True)
    sentences = load_sentences()
    by_id = {s["id"]: s for s in sentences}

    if args.redo:
        targets = []
        for sid in args.redo:
            if sid not in by_id:
                print(f"알 수 없는 id: {sid}", file=sys.stderr)
                sys.exit(1)
            targets.append(by_id[sid])
    else:
        targets = [s for s in sentences if not (AUDIO_DIR / f"{s['id']}.wav").exists()]
        skipped = len(sentences) - len(targets)
        if skipped:
            print(f"이미 녹음된 {skipped}개 문장은 건너뜁니다 (--redo로 재녹음 가능).")

    if not targets:
        print("녹음할 문장이 없습니다. 30문장 모두 완료.")
        return

    print(f"녹음 대상: {len(targets)}개 문장. 마이크: 시스템 기본 입력 장치.")
    for s in targets:
        record_sentence(s, AUDIO_DIR / f"{s['id']}.wav")

    done = sum(1 for s in sentences if (AUDIO_DIR / f"{s['id']}.wav").exists())
    print(f"\n완료. 현재 {done}/{len(sentences)}개 녹음됨.")


if __name__ == "__main__":
    main()
