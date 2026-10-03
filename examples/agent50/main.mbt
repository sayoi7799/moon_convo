// Simulates a 50-round coding agent and trims its history before every model
// call. Each round the agent calls 1-3 tools whose results vary in size; every
// 10 rounds the user sends a new instruction. Output is deterministic.

///|
/// Token budget available for the conversation history.
let budget : Int = 32000

///|
/// Tiny deterministic pseudo-random generator (LCG).
struct Lcg {
  mut state : UInt
}

///|
fn Lcg::next(self : Lcg, n : Int) -> Int {
  self.state = self.state * 1664525U + 1013904223U
  ((self.state >> 8) % n.reinterpret_as_uint()).reinterpret_as_int()
}

///|
let vocab : Array[String] = [
  "fn", "let", "match", "return", "error", "test", "budget", "token", "上下文",
  "工具", "结果", "{", "}", "(", ")", "=>", "\n", "src/trim.mbt", "42",
]

///|
/// About `n` words of file-like text.
fn filler(rng : Lcg, n : Int) -> String {
  let sb = StringBuilder()
  for i in 0..<n {
    if i > 0 {
      sb.write_char(' ')
    }
    sb.write_string(vocab[rng.next(vocab.length())])
  }
  sb.to_string()
}

///|
let tools : Array[String] = ["read_file", "grep", "run_tests"]

///|
fn main {
  let rng = Lcg::{ state: 2026, }
  let history : Array[@convo.Message] = [
    {
      id: "sys",
      pinned: false,
      body: System("You are a careful coding agent."),
    },
    {
      id: "task",
      pinned: true,
      body: User("Make every test in the repo pass."),
    },
  ]
  let mut next_id = 0
  fn fresh(prefix : String) -> String {
    next_id += 1
    "\{prefix}\{next_id}"
  }

  let mut trims = 0
  for round in 1..<=50 {
    if round % 10 == 0 {
      history.push({
        id: fresh("u"),
        pinned: false,
        body: User("Status update \{round}: also keep the build warning-free."),
      })
    }
    let calls : Array[@convo.ToolCall] = []
    for _ in 0..<(1 + rng.next(3)) {
      calls.push({
        id: fresh("call_"),
        name: tools[rng.next(tools.length())],
        arguments: "{\"path\": \"src/file\{rng.next(20)}.mbt\"}",
      })
    }
    history.push({
      id: fresh("a"),
      pinned: false,
      body: Assistant(content="Checking.", tool_calls=calls),
    })
    for c in calls {
      // Mostly medium results, occasionally a huge one.
      let size = if rng.next(8) == 0 { 2500 } else { 100 + rng.next(500) }
      history.push({
        id: fresh("t"),
        pinned: false,
        body: Tool(tool_call_id=c.id, content=filler(rng, size)),
      })
    }
    let (out, report) = @convo.trim(
      history,
      budget,
      @convo.ConservativeEstimator::new(),
    ) catch {
      e => {
        println("round \{round}: trim failed: \{e.to_repr()}")
        return
      }
    }
    history.clear()
    history.append(out)
    println(describe(round, report))
    if report.triggered {
      trims += 1
    }
  }
  println(
    "\n\{trims} of 50 rounds trimmed (prompt cache invalidated); \{50 - trims} kept the cache intact.",
  )
}

///|
fn describe(round : Int, report : @convo.TrimReport) -> String {
  let r = if round < 10 { "0\{round}" } else { "\{round}" }
  if !report.triggered {
    return "round \{r}: \{report.tokens_before} tokens, untouched"
  }
  let mut folded = 0
  let mut dropped = 0
  let mut truncated = 0
  for a in report.actions {
    match a.action {
      Folded => folded += 1
      Dropped => dropped += 1
      Truncated => truncated += 1
      Kept => ()
    }
  }
  let cache = match report.first_modified_index {
    Some(i) => "cache breaks at #\{i}"
    None => "cache intact"
  }
  "round \{r}: \{report.tokens_before} -> \{report.tokens_after} tokens, folded \{folded}, dropped \{dropped}, truncated \{truncated}, \{cache}"
}
