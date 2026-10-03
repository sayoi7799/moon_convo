///|
/// Trims `messages` into `budget` tokens as counted by `counter`.
///
/// Nothing changes while the total is at most budget × high watermark. Above
/// it, the steps below run in order until the total is at most budget × low
/// watermark: fold old tool results, drop the oldest unprotected units,
/// truncate the longest messages. Returns the kept messages in input order
/// and a report with one action per input message.
pub fn[C : TokenCounter] trim(
  messages : Array[Message],
  budget : Int,
  counter : C,
  config? : Config = Config::default(),
) -> (Array[Message], TrimReport) raise TrimError {
  let units = group_units(messages) catch { e => raise Invalid(e) }
  config.check(budget)
  let state = State::new(messages, units, counter, config)
  let target = budget * config.low_water_pct / 100
  if state.total <= budget * config.high_water_pct / 100 {
    return state.finish(budget, target, triggered=false)
  }
  let protected_tokens = state.protected_tokens()
  if protected_tokens > budget {
    raise ProtectedExceedsBudget(protected_tokens~, budget~)
  }
  state.fold(target)
  state.drop_units(target)
  state.truncate(target)
  if state.total > budget {
    raise CannotFit(tokens=state.total, budget~)
  }
  state.finish(budget, target, triggered=true)
}

///|
/// Working copy of a conversation during one `trim` call.
priv struct State[C] {
  input : Array[Message]
  units : Array[AtomicUnit]
  counter : C
  config : Config
  /// Current message, `None` once dropped.
  current : Array[Message?]
  actions : Array[Action]
  /// Reason for a non-Kept action; Kept reasons are derived in `finish`.
  reasons : Array[Reason?]
  tokens_before : Array[Int]
  tokens_now : Array[Int]
  /// Atomic unit index of each message.
  unit_of : Array[Int]
  /// Index of the last user message, -1 if none.
  last_user : Int
  mut total : Int
}

///|
fn[C : TokenCounter] State::new(
  input : Array[Message],
  units : Array[AtomicUnit],
  counter : C,
  config : Config,
) -> State[C] {
  let n = input.length()
  let tokens = input.map(m => counter.count_message(m))
  let unit_of = Array::make(n, 0)
  for u, unit in units {
    for i in unit.indices() {
      unit_of[i] = u
    }
  }
  let mut last_user = -1
  for i, m in input {
    if m.body is User(_) {
      last_user = i
    }
  }
  let mut total = conversation_overhead
  for t in tokens {
    total += t
  }
  {
    input,
    units,
    counter,
    config,
    current: input.map(m => Some(m)),
    actions: Array::make(n, Kept),
    reasons: Array::make(n, None),
    tokens_before: tokens,
    tokens_now: tokens.copy(),
    unit_of,
    last_user,
    total,
  }
}

///|
/// Tokens of the conversation overhead plus all system and pinned messages.
fn[C] State::protected_tokens(self : State[C]) -> Int {
  let mut sum = conversation_overhead
  for i, m in self.input {
    if m.pinned || m.body is System(_) {
      sum += self.tokens_before[i]
    }
  }
  sum
}

///|
fn[C] State::unit_has_pinned(self : State[C], u : Int) -> Bool {
  self.units[u].indices().iter().any(i => self.input[i].pinned)
}

///|
/// Whether unit `u` is a tool round among the `keep_recent_tool_rounds` latest.
fn[C] State::is_recent_round(self : State[C], u : Int) -> Bool {
  let mut later_rounds = 0
  for v in (u + 1)..<self.units.length() {
    if self.units[v] is ToolExchange(..) {
      later_rounds += 1
    }
  }
  self.units[u] is ToolExchange(..) &&
  later_rounds < self.config.keep_recent_tool_rounds
}

///|
fn[C : TokenCounter] State::replace(
  self : State[C],
  i : Int,
  m : Message,
  action : Action,
  reason : Reason,
) -> Unit {
  let t = self.counter.count_message(m)
  self.total += t - self.tokens_now[i]
  self.tokens_now[i] = t
  self.current[i] = Some(m)
  self.actions[i] = action
  self.reasons[i] = Some(reason)
}

///|
/// Step 1: replace tool results of old rounds, oldest first, with a one-line
/// placeholder. Skips pinned results, placeholders, and results the
/// placeholder would not shrink.
fn[C : TokenCounter] State::fold(self : State[C], target : Int) -> Unit {
  for u, unit in self.units {
    guard unit is ToolExchange(assistant~, results~) && !self.is_recent_round(u) else {
      continue
    }
    guard self.input[assistant].body is Assistant(tool_calls~, ..) else {
      continue
    }
    for i in results {
      if self.total <= target {
        return
      }
      let m = self.input[i]
      guard m.body is Tool(tool_call_id~, content~) &&
        !m.pinned &&
        !is_placeholder(content) else {
        continue
      }
      let name = match tool_calls.search_by(c => c.id == tool_call_id) {
        Some(k) => tool_calls[k].name
        None => "tool"
      }
      let text = fold_placeholder(
        self.config.lang,
        name,
        self.counter.count_text(content),
      )
      let folded = { ..m, body: Tool(tool_call_id~, content=text), }
      if self.counter.count_message(folded) < self.tokens_now[i] {
        self.replace(i, folded, Folded, OldToolResult)
      }
    }
  }
}

///|
/// Whether unit `u` may never be dropped: it holds a system or pinned message
/// or the last user message, or is among the `keep_recent_units` latest.
fn[C] State::unit_protected(self : State[C], u : Int) -> Bool {
  u >= self.units.length() - self.config.keep_recent_units ||
  self.unit_has_pinned(u) ||
  (self.last_user >= 0 && self.unit_of[self.last_user] == u) ||
  self.units[u].indices().iter().any(i => self.input[i].body is System(_))
}

///|
/// Step 2: drop whole unprotected units, oldest first.
fn[C] State::drop_units(self : State[C], target : Int) -> Unit {
  for u in 0..<self.units.length() {
    if self.total <= target {
      return
    }
    if self.unit_protected(u) {
      continue
    }
    for i in self.units[u].indices() {
      self.total -= self.tokens_now[i]
      self.tokens_now[i] = 0
      self.current[i] = None
      self.actions[i] = Dropped
      self.reasons[i] = Some(OldestUnit)
    }
  }
}

///|
/// Step 3: truncate the largest remaining non-system, non-pinned message
/// (ties: earliest), each at most once, until the target is reached. Content
/// keeps at least `min_truncate_tokens`; tool-call arguments are never cut.
/// Placeholders and already-truncated text are skipped, which keeps a second
/// `trim` of the output a no-op.
fn[C : TokenCounter] State::truncate(self : State[C], target : Int) -> Unit {
  let tried = Array::make(self.input.length(), false)
  while self.total > target {
    let mut best = -1
    for i, cur in self.current {
      guard cur is Some(m) &&
        !tried[i] &&
        !m.pinned &&
        !(m.body is System(_)) &&
        !is_placeholder(m.text()) &&
        !is_truncated(m.text()) &&
        self.counter.count_text(m.text()) > self.config.min_truncate_tokens else {
        continue
      }
      if best < 0 || self.tokens_now[i] > self.tokens_now[best] {
        best = i
      }
    }
    if best < 0 {
      return
    }
    tried[best] = true
    guard self.current[best] is Some(m) else { return }
    let text_tokens = self.counter.count_text(m.text())
    let want = text_tokens - (self.total - target)
    let want = if want < self.config.min_truncate_tokens {
      self.config.min_truncate_tokens
    } else {
      want
    }
    let cut = m.with_text(
      truncate_text(m.text(), want, self.counter, self.config.lang),
    )
    if self.counter.count_message(cut) < self.tokens_now[best] {
      self.replace(best, cut, Truncated, TooLong)
    }
  }
}

///|
/// Cuts `text` to at most `max_tokens` by keeping its head and tail (half the
/// kept characters each) around a truncation marker. Works on code points, so
/// surrogate pairs are never split. Returns `text` unchanged if it fits; if
/// even the bare marker is over `max_tokens`, returns the bare marker.
pub fn[C : TokenCounter] truncate_text(
  text : String,
  max_tokens : Int,
  counter : C,
  lang : Lang,
) -> String {
  let original = counter.count_text(text)
  if original <= max_tokens {
    return text
  }
  let chars = text.to_array()
  let len = chars.length()
  fn build(keep : Int) -> String {
    let head = String::from_array(chars[:(keep + 1) / 2])
    let tail = String::from_array(chars[len - keep / 2:])
    let removed = original - counter.count_text(head) - counter.count_text(tail)
    head + truncation_marker(lang, removed) + tail
  }

  // Largest number of kept characters that fits.
  let mut lo = 0
  let mut hi = len - 1
  while lo < hi {
    let mid = (lo + hi + 1) / 2
    if counter.count_text(build(mid)) <= max_tokens {
      lo = mid
    } else {
      hi = mid - 1
    }
  }
  build(lo)
}

///|
/// Why message `i` was kept.
fn[C] State::kept_reason(self : State[C], i : Int) -> Reason {
  let u = self.unit_of[i]
  let n_units = self.units.length()
  if self.input[i].body is System(_) {
    System
  } else if self.unit_has_pinned(u) {
    Pinned
  } else if self.last_user >= 0 && self.unit_of[self.last_user] == u {
    LastUser
  } else if self.input[i].body is Tool(_) {
    // Recent units do not protect tool results from folding.
    if self.is_recent_round(u) {
      RecentToolRound
    } else {
      UnderBudget
    }
  } else if u >= n_units - self.config.keep_recent_units {
    RecentUnit
  } else {
    UnderBudget
  }
}

///|
fn[C] State::finish(
  self : State[C],
  budget : Int,
  target : Int,
  triggered~ : Bool,
) -> (Array[Message], TrimReport) {
  let out = []
  let actions = []
  let mut first_modified = None
  for i, m in self.input {
    if self.current[i] is Some(cur) {
      out.push(cur)
    }
    let action = self.actions[i]
    if action != Kept && first_modified is None {
      first_modified = Some(i)
    }
    let reason = match self.reasons[i] {
      Some(r) => r
      None => if triggered { self.kept_reason(i) } else { UnderBudget }
    }
    actions.push({
      id: m.id,
      index: i,
      action,
      reason,
      tokens_before: self.tokens_before[i],
      tokens_after: if self.current[i] is None {
        0
      } else {
        self.tokens_now[i]
      },
    })
  }
  let mut before = conversation_overhead
  for t in self.tokens_before {
    before += t
  }
  let report = {
    triggered,
    budget,
    target,
    tokens_before: before,
    tokens_after: self.total,
    first_modified_index: first_modified,
    actions,
  }
  (out, report)
}
