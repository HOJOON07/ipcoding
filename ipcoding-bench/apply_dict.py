#!/usr/bin/env python3.11
"""apply_dict.py — 태스크 0.4 검증: 시드 사전 치환 후 용어 적중률·CER 재계산.

results_stt.csv에서 대상 모델·조건의 전사문에 dictionary_seed.json을 적용
(긴 spoken 우선 — TDD §3.6)하고 results_stt_postdict.csv로 저장.
원본 CSV는 수정하지 않는다.

사용법:
    .venv/bin/python apply_dict.py \
        --model ggml-large-v3-turbo-q5_0.bin --condition with_prompt
"""

import argparse
import csv
import json
import re
from pathlib import Path

import jiwer

BENCH_DIR = Path(__file__).resolve().parent


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def apply_dictionary(text: str, entries: list[dict]) -> str:
    for e in sorted(entries, key=lambda e: len(e["spoken"]), reverse=True):
        text = text.replace(e["spoken"], e["written"])
    return text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="ggml-large-v3-turbo-q5_0.bin")
    parser.add_argument("--condition", default="with_prompt")
    args = parser.parse_args()

    entries = json.load(open(BENCH_DIR / "dictionary_seed.json", encoding="utf-8"))
    sentences = {s["id"]: s for s in
                 json.load(open(BENCH_DIR / "sentences.json", encoding="utf-8"))}
    rows = [r for r in csv.DictReader(open(BENCH_DIR / "results_stt.csv", encoding="utf-8"))
            if r["model"] == args.model and r["condition"] == args.condition]
    if not rows:
        raise SystemExit(f"해당 조합 없음: {args.model}/{args.condition}")

    out_rows = []
    for r in rows:
        s = sentences[r["sentence_id"]]
        post = apply_dictionary(r["transcript"], entries)
        hits = sum(1 for t in s["terms"] if t in post)
        total = len(s["terms"])
        cer = "" if s["type"] == "E" else f"{jiwer.cer(normalize(s['text']), normalize(post)):.4f}"
        out_rows.append({
            "model": r["model"], "condition": r["condition"] + "+dict",
            "sentence_id": r["sentence_id"], "type": r["type"],
            "transcript": post, "cer": cer,
            "terms_hit": hits, "terms_total": total, "rtf": r["rtf"],
        })

    out = BENCH_DIR / "results_stt_postdict.csv"
    with open(out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(out_rows[0].keys()))
        w.writeheader()
        w.writerows(out_rows)

    hit = sum(r["terms_hit"] for r in out_rows)
    tot = sum(r["terms_total"] for r in out_rows)
    cers = [float(r["cer"]) for r in out_rows if r["cer"] != ""]
    print(f"사전 항목: {len(entries)}개 | 대상: {args.model}/{args.condition}")
    print(f"치환 후 용어 적중률: {hit}/{tot} = {hit/tot:.1%}  (Phase 0 기준 ≥90%)")
    print(f"치환 후 평균 CER(A~D): {sum(cers)/len(cers):.4f}")
    print(f"저장: {out}")
    for r in out_rows:
        if r["terms_hit"] < r["terms_total"]:
            miss = [t for t in sentences[r["sentence_id"]]["terms"] if t not in r["transcript"]]
            print(f"  잔존 미적중 {r['sentence_id']}: {miss} | {r['transcript']}")


if __name__ == "__main__":
    main()
