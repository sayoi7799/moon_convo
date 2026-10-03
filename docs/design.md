# moon-convo 设计文档（MVP）

模块名：`sayoi7799/moon_convo`
工具链：moon 0.1.20260920 / moonc v0.10.14（新版 `moon.mod` / `moon.pkg` 清单格式）

## 1. 目标

在运行时处理 AI 应用的对话消息列表，使其放进 token 预算：
不拆散工具调用与工具结果、尽量少地使提示词缓存失效、给出可审计的裁剪报告。

不做：调用模型摘要、HTTP、多厂商格式互转、内置真实分词器、语义相似度、费用计算。

与现有项目的区别：
- `lllg123/mooncontext`：CI 中审计渲染好的静态文本，按字符计算，不处理消息列表。
- `PingGuoMiaoMiao/MoonRoute`：模型路由与网关，不做裁剪和工具调用配对。
- 本项目：运行时处理消息列表，可作为它们之前或之后的一步。

## 2. 消息模型

```moonbit
pub(all) struct ToolCall { id : String; name : String; arguments : String }

pub(all) enum Body {
  System(String)
  User(String)
  Assistant(content~ : String, tool_calls~ : Array[ToolCall])
  Tool(tool_call_id~ : String, content~ : String)
}

pub(all) struct Message { id : String; pinned : Bool; body : Body }
```

- 角色与内容合并在 `Body` 中，“tool 消息缺少 tool_call_id”等非法状态无法构造。
- JSON 读入（OpenAI chat 结构）：`role`、`content`（字符串或 null）、`tool_calls[].{id, function.{name, arguments}}`、`tool_call_id`。
  扩展字段：`id`（缺省时按输入位置生成 `m0`, `m1`, …）、`pinned`（缺省 false）。
- 提供 `to_json`，输出同一结构（含 `id`、`pinned`），可再次读入。

## 3. 原子单元与校验

```moonbit
enum AtomicUnit {  // 不叫 Unit：避免遮蔽内置 Unit 类型
  Single(Int)                                            // system / user / 无工具调用的 assistant
  ToolExchange(assistant~ : Int, results~ : Array[Int])  // assistant + 其全部工具结果
}
```

- 工具结果必须紧跟在其 assistant 之后（顺序任意），因此每个单元是一段连续下标；整组删除不改变剩余消息相对顺序。
- 单元中任一消息 pinned ⇒ 整个单元不可删除。
- `validate` 的错误（`ValidationError`）：
  - `OrphanToolCall(msg_id, call_id)`：调用没有结果
  - `OrphanToolResult(msg_id, call_id)`：结果没有对应调用
  - `DuplicateToolCallId(msg_id, call_id)`
  - `DuplicateToolResult(msg_id, call_id)`
  - `ToolResultOutOfPlace(msg_id, call_id)`：结果未紧跟其 assistant
  - `DuplicateMessageId(msg_id)`

## 4. Token 计数

```moonbit
pub(open) trait TokenCounter {
  count_text(Self, String) -> Int
  count_message(Self, Message) -> Int  // 有默认实现，可覆盖
}
```

对话总数 = 3（回复起始开销）+ Σ count_message。

### 默认保守估算器 `ConservativeEstimator`

文本按字符类别分段计数：

| 类别 | 规则 |
|---|---|
| 中日韩字符（汉字、假名、韩文） | 每字 1.2：n 个字计 ⌈6n/5⌉ |
| 连续 ASCII 字母/数字 | ⌈长度/3⌉，至少 1 |
| 其中字母与数字混杂或驼峰的段（id、hash、base64） | ⌈2×长度/3⌉ |
| ASCII 标点、符号 | 每个 1 |
| 空白 | 单个空格 0；其他空白段 ⌈长度/4⌉，至少 1 |
| 其他非 ASCII（西里尔、emoji 等） | 每字 2 |

代码不单独识别：上述规则对代码天然偏高（标点逐个计、标识符按 3 字符一段）。

固定开销：
- 每条消息 +8
- 每个工具调用 +12 + 估算(id) + 估算(name) + 估算(arguments)
- tool 消息 + 估算(tool_call_id)

若本机可用 tiktoken，则用中文/英文/代码样本校准并在 README 记录；否则标注为“按设计偏保守，未经真实分词器校准”。

## 5. 裁剪流程

### 配置（`Config`，均有默认值）

| 项 | 默认 | 说明 |
|---|---|---|
| `high_water_pct` | 100 | 超过 预算×高水位 才裁剪 |
| `low_water_pct` | 70 | 一旦裁剪，目标为 预算×低水位；约束 0 < low ≤ high ≤ 100 |
| `keep_recent_tool_rounds`（K） | 3 | 最近 K 个工具调用回合（ToolExchange）的结果不折叠；并行调用属同一回合 |
| `keep_recent_units`（N） | 4 | 最近 N 个原子单元不删除 |
| 最后一条 user 消息 | 始终保留 | 通常是当前任务 |
| `min_truncate_tokens` | 64 | 截断后单条消息至少保留的 token |
| `lang` | `Zh` | 占位文本与截断标记语言：`Zh` / `En` |

理由：agent 每轮约增长预算的 2–5%，裁到 70% 后约 6–15 轮才再裁一次，缓存只在那时失效。
N 按单元计而非按 user 消息计：agent 常在一条 user 指令下连续调用上百次工具，按 user 计会使保护区覆盖全部历史。

### 步骤

总数 ≤ 预算×高水位 ⇒ 原样返回（`triggered = false`）。否则目标 T = 预算×低水位，按顺序执行，任一时刻达到 T 即停止：

0. **前置检查**：system + pinned 消息 + 对话开销 > 预算 ⇒ `ProtectedExceedsBudget`。
1. **折叠工具结果**：最近 K 个回合之外的回合，从最旧开始，将其工具结果替换为占位文本：
   - Zh：`[已省略：read_file 的结果，原长约 3200 tokens]`
   - En：`[omitted: result of read_file, originally ~3200 tokens]`
   占位文本不短于原文时不折叠。pinned 消息不折叠。
2. **整组删除**：从最旧单元开始删除。不删：system、含 pinned 的单元、最近 N 个单元、最后一条 user 消息所在单元。
3. **截断**：每次选当前最长的可截断消息（非 system、非 pinned；同长取下标小者），截到恰好补足差额、但不少于 `min_truncate_tokens`；保留首尾各一半，中间插入标记：
   - Zh：`…[已截断约 N tokens]…`
   - En：`…[truncated ~N tokens]…`
   只截断 `content`，不截断工具调用 `arguments`（会破坏 JSON）。已是折叠占位文本或已含截断标记的消息不再截断。对任意计数器，通过对保留字符数二分查找确定截断点。
4. 仍 > 预算 ⇒ `CannotFit(tokens, budget)`；在 预算 与 T 之间则接受。

### 幂等性

输出 ≤ T ≤ 高水位线 ⇒ 再处理不触发；否则所有阶段已无可操作对象（已折叠的不再折叠，已删的不存在，截断已达下限），再处理不做任何修改。

## 6. 报告

```moonbit
pub(all) struct TrimReport {
  triggered : Bool
  budget : Int
  target : Int
  tokens_before : Int
  tokens_after : Int
  first_modified_index : Int?   // 原输入中第一条被修改/删除的消息下标
  actions : Array[MessageAction] // 与输入一一对应、同序
}
pub(all) struct MessageAction {
  id : String; index : Int
  action : Action   // Kept | Folded | Dropped | Truncated
  reason : Reason   // System | Pinned | RecentUnit | RecentToolRound | LastUser | UnderBudget | OldToolResult | OldestUnit | TooLong
  tokens_before : Int; tokens_after : Int
}
```

`first_modified_index` 通常紧随 system 之后：缓存节省主要来自水位机制减少裁剪次数，而非缩小单次失效范围（README 如实说明）。

### API

```moonbit
pub fn[C : TokenCounter] trim(
  messages : Array[Message], budget : Int, counter : C, config? : Config
) -> (Array[Message], TrimReport) raise TrimError
// TrimError: Invalid(ValidationError) | InvalidConfig(String)
//          | ProtectedExceedsBudget(protected~ : Int, budget~ : Int)
//          | CannotFit(tokens~ : Int, budget~ : Int)
```

## 7. 不变量（属性测试，`moonbitlang/core/quickcheck`）

1. 输出 token 数 ≤ 预算，否则返回错误
2. 无孤立工具调用 / 工具结果（输出通过 `validate`）
3. system 与 pinned 消息全部保留（id 与内容不变）
4. 消息相对顺序不变（输出 id 序列是输入 id 序列的子序列）
5. 确定性：同一输入两次结果相同
6. 幂等：对输出再 trim 一次结果不变

生成器：随机合法对话（system 开头、user / 普通 assistant / 带 1–4 个并行调用的回合、随机 pinned、混合中英文与代码文本、随机预算）。

## 8. 用例测试

JSON 样例以 `#|` 多行字符串内嵌（wasm-gc 无文件系统），写死期望的保留/折叠/删除/截断 id。覆盖：并行工具调用、连续多轮工具调用、超长单条消息、只有 system 即超预算、空对话、各类 validate 错误。

## 9. 目录

```
moon.mod
src/                 库包（单一 import）
  message.mbt json.mbt tokens.mbt units.mbt trim.mbt report.mbt
  *_test.mbt prop_test.mbt
examples/agent50/    main 包：模拟 50 轮 agent 对话，每轮打印裁剪报告
docs/design.md
README.md
```

## 10. 完成标准

- `moon test` 在 js、wasm-gc、native 均通过
- 每条不变量有对应属性测试
- 50 轮示例可运行
- README：安装、最小示例、与 mooncontext / MoonRoute 区别、估算规则、不变量列表
