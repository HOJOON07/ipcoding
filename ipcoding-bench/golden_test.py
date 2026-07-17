#!/usr/bin/env python3
"""골든 테스트 (태스크 2.10, TDD §7) — Phase 0 오디오 30개 파이프라인 자동 회귀.

앱 파이프라인을 CLI로 복제해 스냅샷과 비교한다:
  whisper(turbo q5 + initial_prompt) → 사전 치환(단일 패스 최장매칭) →
  Qwen3.5 9B (v2 ChatML + 씽킹 시드, temp 0.2, seed 0) → 출력 정제 4단계

게이트:
  1. 용어 적중률(치환 후) ≥ 90%  (Phase 0 완료 기준)
  2. 규칙 위반 0건 (<think> 누출, 구분자 에코, 빈 출력)
  3. 골든 스냅샷(golden/)과 diff 없음  (--update-golden으로 갱신)

입력 설정은 리포에 버전된 것만 사용한다 (라이브 사전 편집이 가짜 회귀를 만들지 않게):
  dictionary_seed.json, ../IpCoding/Sources/Refine/refine_v2.txt

주의: 결정성은 동일 llama.cpp/whisper.cpp 빌드 전제 — brew 업그레이드 후엔 스냅샷 재검토·갱신.
실행: .venv/bin/python golden_test.py [--update-golden] [--skip-llm] [--only s01,s02]
exit: 0=통과, 1=회귀(스냅샷 diff·규칙 위반·실행 오류), 2=적중률 게이트만 미달, 3=환경 오류.
      적중률 게이트는 전체 실행에만 적용 (--only 서브셋은 생략).
"""
import argparse
import json
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

BENCH = Path(__file__).resolve().parent
REPO = BENCH.parent
WHISPER_CLI = "/opt/homebrew/bin/whisper-cli"
LLAMA_SERVER = "/opt/homebrew/bin/llama-server"
WHISPER_MODEL = BENCH / "models" / "ggml-large-v3-turbo-q5_0.bin"
QWEN_GGUF = Path.home() / "Library/Application Support/IpCoding/models/Qwen3.5-9B-Q4_K_M.gguf"
PROMPT_V2 = REPO / "IpCoding/Sources/Refine/refine_v2.txt"
DICT_SEED = BENCH / "dictionary_seed.json"
SENTENCES = BENCH / "sentences.json"
AUDIO_DIR = BENCH / "audio"
GOLDEN_DIR = BENCH / "golden"
SERVER_PORT = 8089

# RefineEngine.postProcess ③의 지시문 프리픽스 (Swift와 동일 목록 유지).
INSTRUCTION_PREFIXES = ["출력:", "다듬은 결과:", "정리된 텍스트:", "결과:"]


def load_dictionary():
    entries = json.loads(DICT_SEED.read_text())
    # UserDictionary.load와 동일: spoken 길이 내림차순.
    return sorted(entries, key=lambda e: len(e["spoken"]), reverse=True)


def apply_dictionary(text, entries):
    """UserDictionary.apply 복제 — 왼쪽부터 단일 패스, 각 위치 최장 spoken 치환.
    치환된 written은 재스캔하지 않는다 (연쇄 치환 차단)."""
    result = []
    i = 0
    n = len(text)
    while i < n:
        matched = False
        for e in entries:
            sp = e["spoken"]
            if sp and text.startswith(sp, i):
                result.append(e["written"])
                i += len(sp)
                matched = True
                break
        if not matched:
            result.append(text[i])
            i += 1
    return "".join(result)


def initial_prompt_terms(entries):
    """PromptBuilder.whisperInitialPrompt 복제 — written 중복 제거 후 콤마 결합."""
    seen, terms = set(), []
    for e in entries:
        w = e["written"]
        if w not in seen:
            seen.add(w)
            terms.append(w)
    return ", ".join(terms)


def transcribe(wav, prompt):
    out = subprocess.run(
        [WHISPER_CLI, "-m", str(WHISPER_MODEL), "-l", "ko", "-nt", "-np",
         "--prompt", prompt, "-f", str(wav)],
        capture_output=True, text=True, timeout=120,
    )
    if out.returncode != 0:
        raise RuntimeError(f"whisper 실패: {out.stderr[-300:]}")
    return " ".join(line.strip() for line in out.stdout.splitlines() if line.strip()).strip()


def build_chatml(template, raw_text):
    """PromptBuilder.refinePromptParts + RefineEngine 조립 복제.
    (prefix+delta 전체, delta) 반환 — delta는 Swift의 rawText+suffix에 대응."""
    template = template.replace("{dictionary_pairs}", "(없음)")
    before, after = template.split("{raw_text}")
    prefix = "<|im_start|>user\n" + before
    delta = raw_text + after + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    return prefix + delta, delta


def server_post(path, payload, timeout=120):
    req = urllib.request.Request(
        f"http://127.0.0.1:{SERVER_PORT}{path}", data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def refine(chatml, delta):
    # RefineEngine.swift:148 복제 — maxTokens = min(1024, max(64, 델타토큰×2)).
    n_delta = len(server_post("/tokenize", {"content": delta, "add_special": False},
                              timeout=30)["tokens"])
    out = server_post("/completion", {
        "prompt": chatml,
        "temperature": 0.2, "top_p": 0.9, "repeat_penalty": 1.05,
        # 앱 샘플러 체인(페널티→top_p→temp→dist)과 일치시키기 위해 서버 기본
        # top_k=40 / min_p=0.05를 비활성화.
        "top_k": 0, "min_p": 0.0,
        "seed": 0, "n_predict": min(1024, max(64, n_delta * 2)),
        "stop": ["<|im_end|>"], "cache_prompt": True,
    })
    return out["content"]


def post_process(raw):
    """RefineEngine.postProcess 복제 (①공백/따옴표 ②구분자 ③지시문 프리픽스 ④씽킹 꼬리)."""
    text = raw
    if "</think>" in text:
        text = text.rsplit("</think>", 1)[1]
    text = text.replace("<<<", "").replace(">>>", "").strip()
    for prefix in INSTRUCTION_PREFIXES:
        if text.startswith(prefix):
            text = text[len(prefix):].strip()
            break
    if len(text) >= 2 and text.startswith('"') and text.endswith('"'):
        text = text[1:-1]
    return text


def rule_violations(refined_raw, refined):
    v = []
    if "<think>" in refined:
        v.append("think누출")
    if "<<<" in refined_raw or ">>>" in refined_raw:
        v.append("구분자에코(정제전)")
    if not refined:
        v.append("빈출력")
    return v


def term_hits(text, terms):
    missed = [t for t in terms if t not in text]
    return len(terms) - len(missed), len(terms), missed


def port_in_use():
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{SERVER_PORT}/health", timeout=2)
        return True
    except Exception:
        return False


def start_llama_server():
    proc = subprocess.Popen(
        [LLAMA_SERVER, "-m", str(QWEN_GGUF), "--port", str(SERVER_PORT),
         "-ngl", "99", "-c", "2048"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    for _ in range(120):  # 최대 2분 (6GB 로드)
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{SERVER_PORT}/health", timeout=2)
            return proc
        except Exception:
            if proc.poll() is not None:
                raise RuntimeError("llama-server 조기 종료")
            time.sleep(1)
    proc.kill()
    raise RuntimeError("llama-server 기동 타임아웃")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--update-golden", action="store_true", help="스냅샷 갱신 (사람 검토 후)")
    ap.add_argument("--skip-llm", action="store_true", help="STT+사전만 (빠른 검사)")
    ap.add_argument("--only", help="특정 문장만 (예: s01,s21)")
    args = ap.parse_args()

    # 환경 검증 (실패는 전부 exit 3 — 회귀와 구분)
    if args.update_golden and args.skip_llm:
        print("--update-golden --skip-llm 조합 거부: refined 골든이 null로 파괴된다",
              file=sys.stderr)
        return 3
    required = [WHISPER_CLI, WHISPER_MODEL, PROMPT_V2, DICT_SEED, SENTENCES, AUDIO_DIR]
    if not args.skip_llm:
        required += [LLAMA_SERVER, QWEN_GGUF]
    missing = [str(p) for p in required if not Path(p).exists()]
    if missing:
        print("환경 오류 — 없음: " + ", ".join(missing), file=sys.stderr)
        return 3

    sentences = json.loads(SENTENCES.read_text())
    entries = load_dictionary()
    prompt_terms = initial_prompt_terms(entries)
    template = PROMPT_V2.read_text()
    if template.count("{raw_text}") != 1:
        print("환경 오류 — refine_v2.txt의 {raw_text} 플레이스홀더가 1개가 아님",
              file=sys.stderr)
        return 3
    only = set(t.strip() for t in args.only.split(",") if t.strip()) if args.only else None

    try:
        import jiwer
    except ImportError:
        print("jiwer 없음 — .venv/bin/python으로 실행하세요", file=sys.stderr)
        return 3

    server = None
    if not args.skip_llm:
        if port_in_use():
            print(f"환경 오류 — 포트 {SERVER_PORT}에 이미 서버가 떠 있음 "
                  "(다른 모델일 수 있어 기동 거부 — 종료 후 재실행)", file=sys.stderr)
            return 3
        print("llama-server 기동 중 (6GB 로드)...", flush=True)
        server = start_llama_server()

    GOLDEN_DIR.mkdir(exist_ok=True)
    failures, all_hits, all_total, cers = [], 0, 0, []

    try:
        for s in sentences:
            sid = s["id"]
            if only and sid not in only:
                continue
            wav = AUDIO_DIR / f"{sid}.wav"
            if not wav.exists():
                failures.append(f"{sid}: 오디오 없음")
                continue

            stt_raw = transcribe(wav, prompt_terms)
            stt = apply_dictionary(stt_raw, entries)

            # STT 채점 (A~D만 CER, 용어는 치환 후 — Phase 0 게이트와 동일 지점)
            if s.get("text"):
                norm = lambda t: " ".join(t.split())
                cers.append(jiwer.cer(norm(s["text"]), norm(stt)))
            hits, total, missed = term_hits(stt, s.get("terms", []))
            all_hits += hits
            all_total += total

            line = f"{sid} [{s.get('type','?')}] 용어 {hits}/{total}"
            if missed:
                line += f" (누락: {', '.join(missed)})"

            refined = None
            if not args.skip_llm:
                chatml, delta = build_chatml(template, stt)
                refined_raw = refine(chatml, delta)
                refined = post_process(refined_raw)
                v = rule_violations(refined_raw, refined)
                if v:
                    failures.append(f"{sid}: 규칙 위반 {v}")
                line += f" | 교정 {len(refined)}자"

            # 골든 스냅샷 비교/갱신 (stt + refined)
            snapshot = {"stt": stt, "refined": refined}
            golden_file = GOLDEN_DIR / f"{sid}.json"
            if args.update_golden:
                golden_file.write_text(json.dumps(snapshot, ensure_ascii=False, indent=1))
                line += " | 골든 갱신"
            elif golden_file.exists():
                golden = json.loads(golden_file.read_text())
                for key in ("stt", "refined"):
                    if snapshot.get(key) is not None and golden.get(key) is not None \
                       and snapshot[key] != golden[key]:
                        failures.append(f"{sid}: {key} 스냅샷 불일치\n  골든: {golden[key]}\n  현재: {snapshot[key]}")
                        line += f" | {key} DIFF!"
            else:
                line += " | 골든 없음(--update-golden 필요)"
            print(line, flush=True)
    finally:
        if server:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()

    print("\n===== 골든 테스트 결과 =====")
    hit_rate = all_hits / all_total * 100 if all_total else 0
    avg_cer = sum(cers) / len(cers) if cers else 0
    print(f"용어 적중률(치환 후): {all_hits}/{all_total} = {hit_rate:.1f}%  (게이트 ≥90%)")
    print(f"평균 CER (A~D): {avg_cer:.4f}")

    # 게이트는 전체 실행에만 적용 (--only 서브셋은 스모크 용도 — 항상 미달로 나온다).
    gate_miss = hit_rate < 90 and only is None
    if failures:
        print(f"\n회귀/오류 {len(failures)}건:")
        for f in failures:
            print(f"  ✗ {f}")
        if gate_miss:
            print(f"  ✗ 용어 적중률 게이트 미달: {hit_rate:.1f}% < 90%")
        return 1  # exit 1 = 스냅샷 diff·규칙 위반·실행 오류 (회귀)
    if gate_miss:
        print(f"\n✗ 용어 적중률 게이트 미달: {hit_rate:.1f}% < 90%")
        return 2  # exit 2 = 게이트만 미달 (사전 확장 필요 신호, 회귀 아님)
    print("전체 통과 ✅")
    return 0


if __name__ == "__main__":
    sys.exit(main())
