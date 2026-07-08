#!/usr/bin/env python3.11
"""bench_llm.py — 실험 B: Ollama 후보 LLM × 전사문 교정·정돈 벤치.

후보 4종 (docs/BENCH.md §4 — 실제 Ollama 태그는 실행 시점에 지정):
    - qwen3.5:4b
    - qwen3.5:9b
    - kanana 1.5 8b (gguf 직접 등록 필요)
    - gemma4:e4b
    - (참고) EXAONE 7.8B — 출하 불가, 상한선 측정용

사용법:
    .venv/bin/python bench_llm.py --models qwen3.5:4b qwen3.5:9b
    .venv/bin/python bench_llm.py --models qwen3.5:4b \
        --stt-model ggml-large-v3-turbo-q5_0.bin --stt-condition with_prompt

입력: 기본은 results_stt.csv에서 --stt-model/--stt-condition의 전사문 추출.
      --transcripts <json>으로 직접 지정 가능 ([{"id": "s01", "text": "..."}]).
      dictionary_seed.json이 있으면 전사문에 사전 치환을 먼저 적용
      (실제 파이프라인과 동일 지점 — BENCH.md §4).

측정: TTFT(요청 직전 t0 → 첫 콘텐츠 청크), 총 생성시간(done까지).
      모델 로드 직후 더미 호출 1회 워밍업, ollama ps로 메모리 기록,
      모델 전환 시 keep_alive=0으로 이전 모델 언로드.

출력: results_llm.csv — 자동 컬럼 + 수동 채점용 빈 컬럼(교정성공, 의도보존, 정돈품질, 비고).
"""

import argparse
import csv
import json
import re
import subprocess
import sys
import time
from pathlib import Path

import requests

BENCH_DIR = Path(__file__).resolve().parent
OLLAMA_URL = "http://localhost:11434"


def load_prompt_template(path: Path) -> str:
    with open(path, encoding="utf-8") as f:
        return f.read()


def load_dictionary() -> list[dict]:
    p = BENCH_DIR / "dictionary_seed.json"
    if not p.exists():
        return []
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def dictionary_pairs_text(entries: list[dict]) -> str:
    if not entries:
        return "(없음)"
    return "\n".join(f"{e['spoken']} → {e['written']}" for e in entries)


def apply_dictionary(text: str, entries: list[dict]) -> str:
    """전사 직후 문자열 치환 — 긴 spoken 우선 (부분 매칭 오염 방지, TDD §3.6)."""
    for e in sorted(entries, key=lambda e: len(e["spoken"]), reverse=True):
        text = text.replace(e["spoken"], e["written"])
    return text


def load_transcripts(args) -> list[dict]:
    """[{"id": ..., "text": ...}] 반환."""
    if args.transcripts:
        with open(args.transcripts, encoding="utf-8") as f:
            return json.load(f)

    csv_path = BENCH_DIR / "results_stt.csv"
    if not csv_path.exists():
        print("results_stt.csv 없음 — 먼저 bench_stt.py를 실행하거나 --transcripts를 지정하세요.",
              file=sys.stderr)
        sys.exit(1)
    with open(csv_path, encoding="utf-8") as f:
        rows = list(csv.DictReader(f))

    model = args.stt_model or rows[0]["model"]
    cond = args.stt_condition or next(
        r["condition"] for r in rows if r["model"] == model)
    picked = [r for r in rows if r["model"] == model and r["condition"] == cond]
    if not picked:
        avail = sorted({(r["model"], r["condition"]) for r in rows})
        print(f"해당 조합 없음: {model}/{cond}. 가능한 조합: {avail}", file=sys.stderr)
        sys.exit(1)
    print(f"전사문 출처: {model} / {cond} ({len(picked)}문장)")
    return [{"id": r["sentence_id"], "text": r["transcript"]} for r in picked]


def ollama_ps() -> str:
    try:
        out = subprocess.run(["ollama", "ps"], capture_output=True, text=True, timeout=10)
        return out.stdout.strip()
    except Exception as e:
        return f"(ollama ps 실패: {e})"


def model_memory(model: str) -> str:
    """ollama ps 출력에서 해당 모델의 SIZE 컬럼 추출."""
    for line in ollama_ps().splitlines()[1:]:
        parts = line.split()
        if parts and parts[0].startswith(model.split(":")[0]):
            # NAME ID SIZE(예: "4.7 GB") ...
            m = re.search(r"(\d+(?:\.\d+)?\s*[GM]B)", line)
            if m:
                return m.group(1)
    return ""


def unload(model: str):
    try:
        requests.post(f"{OLLAMA_URL}/api/chat",
                      json={"model": model, "messages": [], "keep_alive": 0},
                      timeout=30)
    except requests.RequestException as e:
        print(f"  ({model} 언로드 실패: {e})", file=sys.stderr)


def chat_stream(model: str, prompt: str, timeout: float = 120.0):
    """(출력텍스트, ttft_s, total_s) 반환. 씽킹 off, temperature 0.2."""
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": True,
        "think": False,
        "options": {"temperature": 0.2},
    }
    t0 = time.perf_counter()
    ttft = None
    chunks = []
    with requests.post(f"{OLLAMA_URL}/api/chat", json=payload,
                       stream=True, timeout=timeout) as resp:
        resp.raise_for_status()
        for line in resp.iter_lines():
            if not line:
                continue
            data = json.loads(line)
            if "error" in data:
                raise RuntimeError(data["error"])
            content = data.get("message", {}).get("content", "")
            if content and ttft is None:
                ttft = time.perf_counter() - t0
            chunks.append(content)
            if data.get("done"):
                total = time.perf_counter() - t0
                return "".join(chunks), (ttft if ttft is not None else total), total
    raise RuntimeError("done 청크 없이 스트림 종료")


def strip_wrapping(text: str) -> tuple[str, str]:
    """마크다운/따옴표 래핑 감지 시 스트립. (정제텍스트, rule_violation 설명) 반환."""
    violations = []
    t = text.strip()

    fence = re.match(r"^```[^\n]*\n(.*?)\n?```$", t, re.DOTALL)
    if fence:
        t = fence.group(1).strip()
        violations.append("markdown_fence")

    for q_open, q_close, name in [('"', '"', "double_quote"), ("'", "'", "single_quote"),
                                  ("“", "”", "curly_quote"), ("「", "」", "corner_bracket")]:
        if len(t) >= 2 and t.startswith(q_open) and t.endswith(q_close):
            t = t[1:-1].strip()
            violations.append(name)

    if re.search(r"(^|\n)\s*([*#]|[-*]\s|\d+\.\s|\*\*)", t):
        violations.append("markdown_inline")  # 남은 마크다운 흔적 — 스트립하지 않고 기록만

    return t, ";".join(violations)


def main():
    parser = argparse.ArgumentParser(description="실험 B: LLM 교정·정돈 벤치")
    parser.add_argument("--models", nargs="+", required=True,
                        help="Ollama 모델 태그 목록 (예: qwen3.5:4b qwen3.5:9b)")
    parser.add_argument("--transcripts", help="전사문 JSON 파일 (기본: results_stt.csv에서 추출)")
    parser.add_argument("--stt-model", help="results_stt.csv에서 추출할 STT 모델명")
    parser.add_argument("--stt-condition", help="results_stt.csv에서 추출할 조건명")
    parser.add_argument("--prompt-file", default="prompts/refine_v0.txt",
                        help="시스템 프롬프트 템플릿 (기본: v0)")
    parser.add_argument("--out", default="results_llm.csv",
                        help="출력 CSV 파일명 (기본: results_llm.csv)")
    parser.add_argument("--no-prompt-dict", action="store_true",
                        help="프롬프트의 {dictionary_pairs}를 '(없음)'으로 비움 "
                             "(입력 사전 치환은 그대로 적용 — 역적용 사고 검증용)")
    args = parser.parse_args()

    template = load_prompt_template(BENCH_DIR / args.prompt_file)
    print(f"프롬프트: {args.prompt_file}")
    dictionary = load_dictionary()
    dict_text = "(없음)" if args.no_prompt_dict else dictionary_pairs_text(dictionary)
    print(f"사전 항목: {len(dictionary)}개 (프롬프트 주입: {'안 함' if args.no_prompt_dict else '함'})")

    transcripts = load_transcripts(args)

    print(f"\n측정 전 ollama ps (백그라운드 모델 상주 확인 — 오염원):\n{ollama_ps()}\n")

    fieldnames = ["model", "sentence_id", "input", "output",
                  "ttft_s", "total_s", "memory", "rule_violation",
                  "교정성공", "의도보존", "정돈품질", "비고"]
    all_rows = []

    for mi, model in enumerate(args.models):
        print(f"\n### {model}")
        # 워밍업 (로드 + 첫 추론 지연 제거)
        try:
            chat_stream(model, "준비 확인. OK라고만 답해라.")
        except Exception as e:
            print(f"{model} 워밍업 실패: {e} — 건너뜀", file=sys.stderr)
            continue
        mem = model_memory(model)
        print(f"  로드 메모리: {mem or '(측정 실패)'}")

        for tr in transcripts:
            input_text = apply_dictionary(tr["text"], dictionary)
            prompt = template.replace("{dictionary_pairs}", dict_text) \
                             .replace("{raw_text}", input_text)
            try:
                raw_out, ttft, total = chat_stream(model, prompt)
            except Exception as e:
                print(f"  {tr['id']}: 요청 실패 — {e}", file=sys.stderr)
                all_rows.append({"model": model, "sentence_id": tr["id"],
                                 "input": input_text, "output": f"(오류: {e})",
                                 "ttft_s": "", "total_s": "", "memory": mem,
                                 "rule_violation": "request_error",
                                 "교정성공": "", "의도보존": "", "정돈품질": "", "비고": ""})
                continue
            output, violation = strip_wrapping(raw_out)
            all_rows.append({"model": model, "sentence_id": tr["id"],
                             "input": input_text, "output": output,
                             "ttft_s": f"{ttft:.3f}", "total_s": f"{total:.3f}",
                             "memory": mem, "rule_violation": violation,
                             "교정성공": "", "의도보존": "", "정돈품질": "", "비고": ""})
            v = f" [위반:{violation}]" if violation else ""
            print(f"  {tr['id']} ttft={ttft:.2f}s total={total:.2f}s{v} | {output}")

        # 모델 전환: 언로드로 메모리 경합 방지
        unload(model)
        if mi < len(args.models) - 1:
            time.sleep(2)

    out = BENCH_DIR / args.out
    with open(out, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(all_rows)
    print(f"\n저장: {out}")
    print("수동 채점 컬럼(교정성공/의도보존/정돈품질/비고)을 채운 뒤 판정하세요.")
    print("판정 순서 (BENCH.md §4): 의도 보존(실패 0건 필수) → 교정 성공률 → 정돈 품질 → TTFT ≤2s → 메모리.")


if __name__ == "__main__":
    main()
