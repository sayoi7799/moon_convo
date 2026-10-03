# moon-convo

**Runtime conversation-history trimmer for LLM agents, written in MoonBit.**
Fits a chat message list into a token budget without ever splitting a tool
call from its result, folds stale tool output first, and trims with high/low
watermarks so the provider's prompt cache is invalidated as rarely as possible.
Every decision is reported per message.

用 MoonBit 编写的**运行时对话历史管理器**。每次调用模型前，把不断变长的消息列表裁剪进 token 预算：
不拆散工具调用与工具结果、优先折叠过时的工具结果、用高低水位减少提示词缓存失效，并对每条消息给出处理报告。

## 解决什么问题

| 常见的坑 | moon-convo 的做法 |
|---|---|
| 对话一长就 `context length exceeded`，临时写“删掉最早几轮” | 统一的裁剪流程：折叠 → 整组删除 → 截断，直到放进预算 |
| 删历史时只删了工具调用、留下工具结果（或反过来），API 报错 | assistant 工具调用 + 全部结果是一个**原子单元**，只能整组删除；`validate` 检查孤立调用/结果 |
| 旧的工具结果（读文件、搜索）占掉大部分 token | 最近 K 个工具回合之外的结果折叠成一行占位文本 |
| 每次都改动前面的消息，提示词缓存频繁失效 | 超过高水位才裁剪，一次裁到低水位；报告给出第一条被修改的位置 |

## 与现有项目的区别

- `lllg123/mooncontext`：在 CI 里审计渲染好的静态文本，按字符计算，不处理消息列表。
- `PingGuoMiaoMiao/MoonRoute`：模型路由和网关，不做消息裁剪和工具调用配对。
- **moon-convo**：运行时处理消息列表，可以作为它们之前或之后的一个步骤使用——
  例如先用 moon-convo 裁剪消息，再交给 MoonRoute 路由；或把裁剪后的结果渲染成文本交给 mooncontext 审计。

## 安装

```bash
moon add sayoi7799/moon_convo
```

在包的 `moon.pkg` 中导入：

```
import {
  "sayoi7799/moon_convo",
}
```

## 最小示例

```mbt check
///|
test "minimal example" {
  let history = @moon_convo.parse_messages(
    (
      #|[{"role": "system", "content": "You are a coding agent."},
      #| {"role": "user", "content": "Why does the build fail?"},
      #| {"role": "assistant", "content": null, "tool_calls": [
      #|   {"id": "c1", "type": "function",
      #|    "function": {"name": "read_file", "arguments": "{\"path\": \"build.log\"}"}}]},
      #| {"role": "tool", "tool_call_id": "c1", "content": "error: unknown symbol `foo` in src/main.mbt:12"},
      #| {"role": "assistant", "content": "`foo` is not defined; rename it to `bar`."}]
    ),
  )
  let (kept, report) = @moon_convo.trim(
    history,
    4000,
    @moon_convo.ConservativeEstimator::new(),
  )
  // Under budget: nothing changes and the prompt cache stays valid.
  assert_eq(kept, history)
  assert_true(!report.triggered)
  assert_eq(report.first_modified_index, None)
  // Send `@moon_convo.messages_to_json(kept)` to the model.
}
```

自定义配置（英文占位文本、更激进的低水位）：

```mbt check
///|
test "custom config" {
  let config = { ..@moon_convo.Config::default(), low_water_pct: 60, lang: En, }
  let (_, report) = @moon_convo.trim(
    [],
    1000,
    @moon_convo.ConservativeEstimator::new(),
    config~,
  )
  assert_eq(report.tokens_before, 3)
}
```

可运行的 50 轮 agent 模拟（每轮打印一行裁剪报告）：

```bash
moon run examples/agent50
```

```
round 12: 26843 tokens, untouched
round 13: 32985 -> 20551 tokens, folded 13, dropped 0, truncated 0, cache breaks at #3
...
round 43: 32645 -> 21957 tokens, folded 9, dropped 0, truncated 0, cache breaks at #101
7 of 50 rounds trimmed (prompt cache invalidated); 43 kept the cache intact.
```

## 工作原理

### 消息模型

```
Message { id, pinned, body }
Body = System(text) | User(text)
     | Assistant(content, tool_calls: [ToolCall { id, name, arguments }])
     | Tool(tool_call_id, content)
```

`parse_messages` / `messages_from_json` 读入 OpenAI chat 结构；额外支持 `id`（缺省为 `m<下标>`）和 `pinned`（缺省 false）。
`messages_to_json` 写回同一结构。`content` 只支持字符串或 null。

### 原子单元

一条带工具调用的 assistant 消息，加上紧跟其后的全部工具结果，是一个 `ToolExchange` 单元；其余每条消息各自是一个 `Single` 单元。
`validate` / `group_units` 返回 `ValidationError`：`OrphanToolCall`、`OrphanToolResult`、`DuplicateToolCallId`、
`DuplicateToolResult`、`ToolResultOutOfPlace`、`DuplicateMessageId`。

### 裁剪流程

总 token ≤ 预算 × 高水位时原样返回。否则以 **预算 × 低水位** 为目标，依次执行，达到目标即停止：

0. **前置检查**：system + pinned 消息（加对话开销）超出预算 → `ProtectedExceedsBudget`，绝不静默截断它们。
1. **折叠工具结果**：最近 K 个工具回合之外的结果，从最旧开始替换为一行占位文本
   `[已省略：read_file 的结果，原长约 3200 tokens]` / `[omitted: result of read_file, originally ~3200 tokens]`。
   pinned 结果、已折叠的结果、占位文本不比原文短的结果不折叠。
2. **整组删除**：从最旧的单元开始删除。永不删除：system、含 pinned 消息的单元、最近 N 个单元、最后一条 user 消息所在单元。
3. **截断**：每次选当前最长的非 system、非 pinned 消息，保留首尾、中间插入 `…[已截断约 N tokens]…`，
   内容至少保留 `min_truncate_tokens`。已折叠或已截断过的消息不再截断（保证幂等）。只截断 `content`，不截断工具参数（否则 JSON 损坏）。按码点切分，不会拆开 emoji。
4. 仍超出预算 → `CannotFit`；介于低水位和预算之间则接受。

### 默认配置

| 字段 | 默认 | 理由 |
|---|---|---|
| `high_water_pct` | 100 | 不超预算就不动，缓存完全保留 |
| `low_water_pct` | 70 | agent 每轮约增长预算的 2–5%，留 30% 余量后约 6–15 轮才再裁一次 |
| `keep_recent_tool_rounds` (K) | 3 | 按回合计：并行调用的多个结果属于同一回合，一起保留或一起折叠 |
| `keep_recent_units` (N) | 4 | 按原子单元计，不按 user 消息计——agent 常在一条指令下连续调用上百次工具 |
| 最后一条 user 消息 | 始终保留 | 通常就是当前任务 |
| `min_truncate_tokens` | 64 | 截断后仍保留可读的首尾 |
| `lang` | `Zh` | 占位文本与截断标记语言，可选 `En` |

### 报告与提示词缓存

`TrimReport` 包含裁剪前后 token 数、目标值，以及**每条输入消息**的 `MessageAction { id, index, action, reason, tokens_before, tokens_after }`：
`action` ∈ `Kept / Folded / Dropped / Truncated`，`reason` ∈ `System / Pinned / RecentUnit / RecentToolRound / LastUser / UnderBudget / OldToolResult / OldestUnit / TooLong`。

`first_modified_index` 是第一条被修改或删除的消息在输入中的位置：提示词缓存从这里开始失效，`None` 表示可完整复用。
说明：一旦裁剪，这个位置通常很靠前（紧随 system 之后），**省钱主要来自水位机制减少裁剪次数**，而不是缩小单次失效范围。
不过已折叠的结果不会再被改动，所以随着对话推进，后续裁剪的起点会逐渐后移（示例中从 #3 移到 #101）。

## Token 估算

`TokenCounter` trait：实现 `count_text` 即可接入真实分词器；默认的 `count_message` 加上每条消息的固定开销，也可以覆盖。

```mbt check
///|
struct LengthCounter {}

///|
impl @moon_convo.TokenCounter for LengthCounter with fn count_text(_, s) {
  s.length()
}

///|
test "plug in your own counter" {
  let (_, report) = @moon_convo.trim([], 100, LengthCounter::{ })
  assert_eq(report.tokens_before, 3)
}
```

默认 `ConservativeEstimator` 按字符类别分段计数，目标是**宁可多估**：

| 类别 | 规则 |
|---|---|
| 中日韩字符（汉字、假名、韩文） | 每字 1.2：n 个字计 ⌈6n/5⌉ |
| 连续 ASCII 字母/数字 | ⌈长度/3⌉，至少 1 |
| 其中“像随机串”的段：字母与数字混杂，或驼峰（如 `call_Xy7Q`、base64、`fileName`） | ⌈2×长度/3⌉（每 1.5 字符 1 个） |
| ASCII 标点、符号 | 每个 1 |
| 空白 | 单个空格 0；其他空白段 ⌈长度/4⌉，至少 1 |
| 其他非 ASCII（西里尔、emoji 等） | 每字 2 |

固定开销：每条消息 +8；每个工具调用 +12 + 估算(id) + 估算(name) + 估算(arguments)；tool 消息 + 估算(tool_call_id)；整段对话 +3。
代码不单独识别：标点逐个计、标识符按 3 字符一段，对代码天然偏高。

**校准**（`python tools/calibrate.py`，对比 tiktoken `cl100k_base`；比值 < 1 表示少估）：

| 样本 | 估算 | cl100k | 比值 |
|---|---|---|---|
| 中文常规文本 | 74 | 60 | 1.23 |
| 中文技术文本 | 62 | 53 | 1.17 |
| 英文 | 60 | 29 | 2.07 |
| Python / JSON / MoonBit 代码 | 78 / 87 / 98 | 43 / 47 / 51 | 1.8–1.9 |
| 日文 | 54 | 43 | 1.26 |
| emoji 混合 | 26 | 21 | 1.24 |
| **生僻汉字**（饕餮魑魅…） | 14 | 30 | **0.47** |
| **随机 id / base64** | 43 | 47 | **0.91** |
| **时间戳、数字混合** | 31 | 32 | **0.97** |

已知局限：生僻汉字（约 0.47）、随机字母数字串（约 0.91，已按 1.5 字符/token 计仍略少估）、密集数字（约 0.97）会**少估**。需要严格上界时，请通过 `TokenCounter` 接入真实分词器。
（`o200k_base` 未校准：运行环境无法下载该编码。）

## 不变量

以下性质对任意合法输入都成立，每条都有 quickcheck 属性测试（`prop_test.mbt`，每条 300 个随机对话；另有一条在随机配置下——任意高低水位、K、N、截断下限、语言——检查预算、配对和幂等）：

1. 输出的 token 数 ≤ 预算，否则返回 `ProtectedExceedsBudget` / `CannotFit` 错误
2. 不存在孤立的工具调用或工具结果（输出通过 `validate`）
3. system 和 pinned 消息全部原样保留
4. 消息的相对顺序不变
5. 确定性：同样的输入永远得到同样的输出
6. 幂等：对输出再处理一次，结果不变

## 明确不做（MVP）

调用模型生成摘要、发送 HTTP 请求、多家厂商格式互转、内置真实分词器、语义相似度挑选、费用计算。

## 开发

```bash
moon test --target all
```

`js`、`wasm-gc`、`native` 三个后端均通过。设计文档见 `docs/design.md`。

## License

Apache-2.0
