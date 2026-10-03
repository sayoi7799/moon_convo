"""Compare ConservativeEstimator with real tokenizers (tiktoken).

Usage: python tools/calibrate.py [encoding ...]
Needs: pip install tiktoken (downloads encodings on first use).
Prints, per sample, our estimate, the real counts, and estimate / real.
A ratio below 1.0 means the estimator UNDER-counted that sample.
"""

import subprocess
import sys
import tiktoken

SAMPLES = {
    "zh prose": "上下文窗口是有限的。每次调用模型之前，我们都需要把不断变长的对话历史裁剪到预算以内，同时不能拆散工具调用和工具结果。",
    "zh technical": "使用 MoonBit 编写的运行时对话历史管理器，支持高低水位、工具结果折叠以及提示词缓存友好的裁剪策略。",
    "zh rare chars": "饕餮魑魅魍魉龘靐齉麤爩",
    "en prose": "The context window is finite. Before every model call we must trim the ever-growing conversation history into the budget without splitting tool calls from their results.",
    "en long words": "internationalization incomprehensibilities counterrevolutionaries electroencephalographically",
    "python": "def fold(results, keep=3):\n    for i, r in enumerate(results[:-keep]):\n        r.content = f\"[omitted: {r.name}, ~{r.tokens} tokens]\"\n    return results\n",
    "json": '{"role": "assistant", "tool_calls": [{"id": "call_8f3a2b", "function": {"name": "read_file", "arguments": "{\\"path\\": \\"src/main.rs\\"}"}}]}',
    "moonbit": "pub fn[C : TokenCounter] trim(messages : Array[Message], budget : Int, counter : C) -> TrimReport raise TrimError {\n  let total = count_conversation(messages, counter)\n  guard total > budget else { return report }\n}\n",
    "shell log": "$ moon test --target native\nTotal tests: 128, passed: 128, failed: 0.\n    Finished in 3.42s\n",
    "numbers": "2026-10-03 12:34:56.789 id=9876543210 lat=31.2304 lon=121.4737",
    "mixed zh/en/code": "请把 `src/trim.mbt` 里的 fold_tool_results 函数改成从最旧的回合开始折叠，K 默认为 3。",
    "japanese": "コンテキストウィンドウには限りがあります。ツール呼び出しと結果を分割してはいけません。",
    "russian": "Контекстное окно ограничено, поэтому историю диалога нужно обрезать.",
    "emoji": "Done ✅ 🚀🚀 tests passed 🎉 — next step ➡️ deploy",
    "uuid/base64": "call_Xy7Qm2LpZ9aB3cD4eF5gH6 dGhlIHF1aWNrIGJyb3duIGZveCBqdW1wcw==",
}

# Pass encoding names as arguments, e.g. `cl100k_base o200k_base`.
ENCODINGS = sys.argv[1:] or ["cl100k_base"]


def ours(texts):
    out = subprocess.run(
        ["moon", "run", "tools/estimate", "--"] + texts,
        capture_output=True, text=True, encoding="utf-8", check=True,
    ).stdout.split()
    return [int(x) for x in out]


def main():
    names = list(SAMPLES)
    estimates = ours([SAMPLES[n] for n in names])
    encs = {e: tiktoken.get_encoding(e) for e in ENCODINGS}
    header = f"{'sample':<18}{'ours':>6}" + "".join(f"{e:>13}" for e in ENCODINGS) + "   min ratio"
    print(header)
    worst = None
    for name, est in zip(names, estimates):
        reals = [len(encs[e].encode(SAMPLES[name])) for e in ENCODINGS]
        ratio = min(est / r for r in reals)
        worst = ratio if worst is None else min(worst, ratio)
        print(f"{name:<18}{est:>6}" + "".join(f"{r:>13}" for r in reals) + f"{ratio:>12.2f}")
    print(f"\nworst ratio (estimate / real): {worst:.2f}")


if __name__ == "__main__":
    main()
