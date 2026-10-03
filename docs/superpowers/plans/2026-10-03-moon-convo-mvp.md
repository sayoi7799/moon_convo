# moon-convo MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A MoonBit library that trims a vendor-neutral chat message list into a token budget without orphaning tool calls/results, with cache-friendly watermarks and a per-message report.

**Architecture:** One library package `src/` split into focused files (model → json → tokens → units → trim → report), one example main package `examples/agent50/`. Trimming is a staged pipeline (fold → drop units → truncate) driven by a pluggable `TokenCounter` trait.

**Tech Stack:** MoonBit (moon 0.1.20260920, moonc v0.10.14), `moonbitlang/core/json`, `moonbitlang/core/quickcheck`.

**Spec:** `docs/design.md`

## Global Constraints

- Module name `sayoi7799/moon_convo`; new-style `moon.mod` / `moon.pkg` manifests (not `*.json`).
- After every task: `moon check` and `moon test` pass before committing; one non-empty commit per task, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Final gate: `moon test --target js`, `--target wasm-gc`, `--target native` all pass.
- Any MoonBit syntax/API not already confirmed: verify with a scratch test or `~/.moon/lib/core` sources before relying on it. Do not guess.
- Defaults (verbatim from spec): high 100, low 70, K = 3 tool rounds, N = 4 units, last user message always kept, `min_truncate_tokens` 64, `lang` default `Zh`.
- Estimator: CJK ⌈6n/5⌉; ASCII alnum run ⌈len/3⌉ min 1; ASCII punct 1; single space 0, other whitespace run ⌈len/4⌉ min 1; other non-ASCII 2/char; per message +8; per tool call +12 + est(id)+est(name)+est(arguments); tool msg + est(tool_call_id); conversation +3.
- Placeholder copy: Zh `[已省略：{name} 的结果，原长约 {n} tokens]` / En `[omitted: result of {name}, originally ~{n} tokens]`. Truncation marker: Zh `…[已截断约 {n} tokens]…` / En `…[truncated ~{n} tokens]…`.
- No HTTP, no model calls, no real tokenizer, no multi-vendor conversion.
- Test fixtures are inline `#|` strings (wasm-gc has no filesystem).
- After each module, give the user a 3–5 sentence Chinese explanation of its core logic (for the defense).

## Review Focus

1. Truncating text containing non-BMP chars (emoji): MoonBit strings are UTF-16; a cut must never split a surrogate pair → test in Task 5.
2. Assistant message with tool calls and `content: null`, and tool result with empty content → decodes; empty content counts as 0 text tokens → test in Task 1.
3. OpenAI multi-part `content` (array) or unknown `role` → clear `DecodeError`, not a crash → test in Task 1.
4. A protected message whose irreducible part (tool-call arguments, overhead) alone exceeds the budget → `CannotFit`, never an over-budget output → test in Task 5.
5. `budget` ≤ 3 or `low > high` → `InvalidConfig` / `ProtectedExceedsBudget` instead of division/loop oddities → test in Task 4.

---

### Task 1: Scaffold, message model, JSON in/out

**Files:**
- Create: `moon.mod`, `src/moon.pkg`, `src/message.mbt`, `src/json.mbt`, `src/json_test.mbt`, `.gitignore` (`_build/`, `target/`, `.mooncakes/`)

**Interfaces:**
- Produces: `ToolCall`, `Body`, `Message` exactly as spec §2; `fn Message::role_name(Self) -> String` (`"system"|"user"|"assistant"|"tool"`); `fn Message::text(Self) -> String` (content of any body); `suberror DecodeError String`; `pub fn messages_from_json(Json) -> Array[Message] raise DecodeError`; `pub fn parse_messages(String) -> Array[Message] raise DecodeError` (parses text then decodes); `pub fn messages_to_json(Array[Message]) -> Json`.

- [ ] **Step 1:** Run `moon new` in scratch to see generated manifest syntax; write `moon.mod` (`name = "sayoi7799/moon_convo"`, version 0.1.0, license Apache-2.0) and `src/moon.pkg` importing `moonbitlang/core/json`. `moon check` passes on an empty package.
- [ ] **Step 2: Failing tests** in `src/json_test.mbt`:
  - `"decode basic roles"`: system/user/assistant/tool sample → 4 messages, ids `m0..m3`, all `pinned == false`.
  - `"decode explicit id and pinned"`: `{"id":"sys","pinned":true,...}` → `id == "sys"`, `pinned`.
  - `"decode parallel tool calls with null content"`: assistant `content:null` + 2 tool_calls → `Assistant(content="", tool_calls.length()==2)`, call name/arguments preserved.
  - `"decode errors"`: content array, unknown role `"developer"`, tool message without `tool_call_id`, non-array top level → each raises `DecodeError`.
  - `"round trip"`: `messages_from_json(messages_to_json(ms)) == ms` (derive `Eq, Show` on model types).
- [ ] **Step 3:** Run `moon test` → FAIL (undefined).
- [ ] **Step 4:** Implement model and codec. Missing `id` → `"m" + index`.
- [ ] **Step 5:** `moon check && moon test` → PASS.
- [ ] **Step 6:** Commit `feat: message model and OpenAI-style JSON codec`.

### Task 2: TokenCounter trait and conservative estimator

**Files:** Create `src/tokens.mbt`, `src/tokens_test.mbt`

**Interfaces:**
- Consumes: `Message`, `Body`.
- Produces: `pub(open) trait TokenCounter { count_text(Self, String) -> Int; count_message(Self, Message) -> Int }` with default `count_message` per Global Constraints; `pub struct ConservativeEstimator {}` + `pub fn ConservativeEstimator::new() -> ConservativeEstimator`; `pub let conversation_overhead : Int = 3`; `pub fn[C : TokenCounter] count_conversation(Array[Message], C) -> Int`.

- [ ] **Step 1:** Scratch-verify trait default-method syntax for this compiler (if unsupported: make `count_message` required and expose `pub fn[C : TokenCounter] default_count_message(C, Message) -> Int`; record which in the commit message).
- [ ] **Step 2: Failing tests** (`ConservativeEstimator::new().count_text(...)`):
  - `""` → 0; `"hello"` → 2; `"hello world"` → 4 (2 + 0 + 2); `"12345"` → 2; `"a+b"` → 3.
  - `"你好世界吗"` (5) → 6; `"你好"` → 3 (⌈12/5⌉).
  - `"a\n\n  b"` → 1 + 1 + 1 = 3 (whitespace run of 4 → 1).
  - `"é"` → 2; `"😀"` → 2 (one code point, not two UTF-16 units).
  - `count_message` user `"hello"` → 10; assistant `""` with one call (id `"c1"`, name `"ls"`, args `"{}"`) → 8 + 12 + 1 + 1 + 2 = 24; tool result `tool_call_id "c1"`, content `"ok"` → 8 + 1 + 1 = 10.
  - `count_conversation([])` → 3.
- [ ] **Step 3:** `moon test` → FAIL. **Step 4:** implement (iterate by code point; CJK = U+3040–30FF, U+3400–4DBF, U+4E00–9FFF, U+F900–FAFF, U+AC00–D7AF, U+20000–2FFFF). **Step 5:** PASS.
- [ ] **Step 6:** If `python -c "import tiktoken"` works, compare against `cl100k_base` and `o200k_base` on ~10 zh/en/code samples; save script under `tools/calibrate.py` and numbers for README. Otherwise note "uncalibrated".
- [ ] **Step 7:** Commit `feat: pluggable token counter with conservative estimator`.

### Task 3: Atomic units and validation

**Files:** Create `src/units.mbt`, `src/units_test.mbt`

**Interfaces:**
- Produces: `pub(all) enum AtomicUnit { Single(Int); ToolExchange(assistant~ : Int, results~ : Array[Int]) }`; `fn AtomicUnit::start(Self) -> Int`, `fn AtomicUnit::end(Self) -> Int` (inclusive), `fn AtomicUnit::indices(Self) -> Array[Int]`; `pub(all) suberror ValidationError` with the six variants of spec §3; `pub fn validate(Array[Message]) -> Unit raise ValidationError`; `pub fn group_units(Array[Message]) -> Array[AtomicUnit] raise ValidationError` (validates, then groups).

- [ ] **Step 1: Failing tests:** valid parallel-call conversation → units `[Single(0), Single(1), ToolExchange(2,[3,4]), Single(5)]`; results in reverse call order still valid; each error variant with its offending ids: call without result → `OrphanToolCall("m2","c2")`; result with unknown id → `OrphanToolResult`; repeated call id across two assistants → `DuplicateToolCallId`; two results for one call → `DuplicateToolResult`; result separated from its assistant by a user message → `ToolResultOutOfPlace`; repeated message id → `DuplicateMessageId`; empty list → `[]`.
- [ ] **Step 2:** FAIL. **Step 3:** implement (single left-to-right pass; checks run in message order so the first error is deterministic). **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat: atomic tool-exchange units and validation`.

### Task 4: Config, report types, pre-check and folding stage

**Files:** Create `src/config.mbt`, `src/report.mbt`, `src/trim.mbt`, `src/trim_test.mbt`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `pub(all) enum Lang { Zh; En }`; `pub(all) struct Config { high_water_pct, low_water_pct, keep_recent_tool_rounds, keep_recent_units, min_truncate_tokens : Int; lang : Lang }` + `pub fn Config::default() -> Config`; `Action`, `Reason`, `MessageAction`, `TrimReport` per spec §6; `pub(all) suberror TrimError { Invalid(ValidationError); InvalidConfig(String); ProtectedExceedsBudget(protected~ : Int, budget~ : Int); CannotFit(tokens~ : Int, budget~ : Int) }`; `pub fn[C : TokenCounter] trim(Array[Message], Int, C, config? : Config = Config::default()) -> (Array[Message], TrimReport) raise TrimError`; `pub fn fold_placeholder(Lang, String, Int) -> String`.

Internal state: a working array of `(Message?, Action, Reason, tokens_before)` indexed like the input; the output is the non-dropped messages in order. `trim` = validate → config check → total ≤ ⌊budget·high/100⌋ ⇒ all `Kept/UnderBudget`, `triggered=false` → protected pre-check → fold → (Task 5 stages) → build report. `target = ⌊budget·low/100⌋`.

- [ ] **Step 1: Failing tests:**
  - `"under budget is untouched"`: output == input, `triggered == false`, `first_modified_index == None`.
  - `"invalid config"`: low 80/high 70, low 0, high 101, budget 0 → `InvalidConfig`.
  - `"only system over budget"`: one 200-token system, budget 50 → `ProtectedExceedsBudget(protected=…, budget=50)`.
  - `"empty conversation"`: `[]`, budget 10 → `[]`, tokens_before 3.
  - `"fold old tool results only"`: 5 tool rounds of big `read_file` results, budget set so folding alone reaches target → rounds 1–2 `Folded/OldToolResult`, rounds 3–5 `Kept/RecentToolRound`, folded content == `fold_placeholder(Zh,"read_file",n)`; same with `lang=En` matches En copy.
  - `"fold stops at target"`: only the oldest round folded when that suffices.
  - `"fold skips when placeholder not shorter"` and `"pinned tool result not folded"`.
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat: trim pipeline skeleton with watermarks and tool-result folding`.

### Task 5: Unit dropping, truncation, CannotFit, first_modified_index

**Files:** Modify `src/trim.mbt`; extend `src/trim_test.mbt`

**Interfaces:** Consumes Task 4. Produces `pub fn[C : TokenCounter] truncate_text(String, Int, C, Lang) -> String` (result counts ≤ max tokens unless max < marker cost; head/tail halves; never splits a surrogate pair; binary search on kept code points).

- [ ] **Step 1: Failing tests:**
  - `"drop oldest units first"`: user/assistant chatter; oldest units `Dropped/OldestUnit`, last 4 units `Kept/RecentUnit`, system `Kept/System`.
  - `"tool exchange dropped whole"`: a ToolExchange is either fully present or fully absent; output passes `validate`.
  - `"last user message kept even outside N"`: one user msg followed by 10 tool rounds → user msg `Kept/LastUser`.
  - `"pinned unit kept"`: pinned message in the middle survives with `Kept/Pinned`.
  - `"truncate overlong message"`: single 5 000-token user msg in recent units, budget 1 000 → `Truncated/TooLong`, contains marker, output total ≤ budget.
  - `"truncate keeps emoji intact"`: text of 😀 repeated → truncated string has no lone surrogate.
  - `"cannot fit"`: recent assistant with 3 000-token arguments, budget 500 → `CannotFit`.
  - `"first_modified_index"`: equals smallest input index whose action ≠ `Kept`.
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat: unit dropping, head-tail truncation and fit errors`.

### Task 6: Case tests from JSON scenarios

**Files:** Create `src/cases_test.mbt`

- [ ] **Step 1:** Write scenarios as `#|` JSON + budget + expected `(id, Action)` lists: parallel tool calls (1 assistant, 3 calls), consecutive tool rounds (6 rounds), overlong single message, system-only over budget (expects error), empty conversation, mixed zh/en/code. Helper `check_case(json, budget, expected : Array[(String, Action)])`.
- [ ] **Step 2:** `moon test` → PASS (fix implementation bugs found; do not edit expectations to match bugs without re-deriving them by hand).
- [ ] **Step 3:** Commit `test: JSON scenario cases`.

### Task 7: Property tests for all invariants

**Files:** Create `src/prop_test.mbt`; modify `src/moon.pkg` (`moonbitlang/core/quickcheck` for "test")

- [ ] **Step 1:** Read `~/.moon/lib/core/quickcheck/README.mbt.md` and generator API; write a generator for legal conversations (optional system first; units: user / plain assistant / round with 1–4 parallel calls; random pinned ~10%; texts mixing ASCII words, CJK, code punctuation, emoji, lengths 0–2 000 chars) and a budget in [50, 3× total].
- [ ] **Step 2:** One named property test per invariant, ≥ 200 cases each: `prop_within_budget_or_error`, `prop_no_orphans`, `prop_system_and_pinned_kept`, `prop_order_preserved` (output ids are a subsequence), `prop_deterministic`, `prop_idempotent` (trim(output) returns same messages and `triggered == false` or no actions ≠ Kept).
- [ ] **Step 3:** `moon test` → PASS. **Step 4:** Commit `test: quickcheck properties for trim invariants`.

### Task 8: 50-round agent example

**Files:** Create `examples/agent50/moon.pkg` (main, imports `sayoi7799/moon_convo/src`), `examples/agent50/main.mbt`

- [ ] **Step 1:** Deterministic simulation (no RNG beyond a fixed LCG): system + task user msg; each round appends assistant with 1–3 tool calls (`read_file`/`grep`/`run_tests`) and sized results; every 10 rounds a new user message. Each round: `trim(history, 8000, estimator)`, set `history = output`, print one line `round 07: 9120 -> 5480 tokens, folded 3, dropped 2, truncated 0, cache breaks at #1` or `round 08: 6010 tokens, untouched`.
- [ ] **Step 2:** `moon run examples/agent50` prints 50 lines, never errors; trims happen only on some rounds (shows watermark effect).
- [ ] **Step 3:** Commit `feat: 50-round agent simulation example`.

### Task 9: README and cross-backend verification

**Files:** Create `README.md` (Chinese, with brief English summary), `LICENSE` (Apache-2.0)

- [ ] **Step 1:** README sections: install (`moon add sayoi7799/moon_convo`), minimal example (parse JSON → trim → print report), differences vs `lllg123/mooncontext` and `PingGuoMiaoMiao/MoonRoute` (spec §1 wording), estimation rules table + calibration result, config defaults with rationale, invariants list, cache note on `first_modified_index`.
- [ ] **Step 2:** Run `moon test --target js`, `moon test --target wasm-gc`, `moon test --target native` → all PASS (native needs a C compiler; if missing, report it to the user rather than skipping silently).
- [ ] **Step 3:** Commit `docs: README with usage, estimation rules and invariants`.
