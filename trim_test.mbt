///|
/// `n` tokens of filler for the default estimator: each "abc" is one token and
/// a single space is free.
fn words(n : Int) -> String {
  let sb = StringBuilder()
  for i in 0..<n {
    if i > 0 {
      sb.write_char(' ')
    }
    sb.write_string("abc")
  }
  sb.to_string()
}

///|
fn sys(id : String, text : String) -> @moon_convo.Message {
  { id, pinned: false, body: System(text), }
}

///|
fn user(id : String, text : String) -> @moon_convo.Message {
  { id, pinned: false, body: User(text), }
}

///|
/// An assistant message `a<k>` calling `read_file` as `c<k>`, and its result
/// `t<k>` with `n` tokens of content.
fn round(k : Int, n : Int) -> Array[@moon_convo.Message] {
  let call : @moon_convo.ToolCall = {
    id: "c\{k}",
    name: "read_file",
    arguments: "{}",
  }
  [
    {
      id: "a\{k}",
      pinned: false,
      body: Assistant(content="", tool_calls=[call]),
    },
    {
      id: "t\{k}",
      pinned: false,
      body: Tool(tool_call_id="c\{k}", content=words(n)),
    },
  ]
}

///|
fn pin(m : @moon_convo.Message) -> @moon_convo.Message {
  { ..m, pinned: true, }
}

///|
fn estimator() -> @moon_convo.ConservativeEstimator {
  @moon_convo.ConservativeEstimator::new()
}

///|
fn run(
  ms : Array[@moon_convo.Message],
  budget : Int,
  config? : @moon_convo.Config = @moon_convo.Config::default(),
) -> (Array[@moon_convo.Message], @moon_convo.TrimReport) raise {
  @moon_convo.trim(ms, budget, estimator(), config~)
}

///|
fn action_of(
  report : @moon_convo.TrimReport,
  id : String,
) -> (@moon_convo.Action, @moon_convo.Reason) {
  for a in report.actions {
    if a.id == id {
      return (a.action, a.reason)
    }
  }
  abort("no action for \{id}")
}

///|
/// System, user, then five read_file rounds of 1000 tokens each.
fn five_rounds() -> Array[@moon_convo.Message] {
  let ms = [sys("s", "be brief"), user("u", "fix the bug")]
  for k in 1..<=5 {
    ms.append(round(k, 1000))
  }
  ms
}

///|
test "default config values" {
  let c = @moon_convo.Config::default()
  assert_eq(c.high_water_pct, 100)
  assert_eq(c.low_water_pct, 70)
  assert_eq(c.keep_recent_tool_rounds, 3)
  assert_eq(c.keep_recent_units, 4)
  assert_eq(c.min_truncate_tokens, 64)
  assert_eq(c.lang, Zh)
}

///|
test "under budget is untouched" {
  let ms = five_rounds()
  let (out, report) = run(ms, 100000)
  assert_eq(out, ms)
  assert_true(!report.triggered)
  assert_eq(report.first_modified_index, None)
  assert_eq(report.tokens_before, report.tokens_after)
  assert_eq(report.actions.length(), ms.length())
  assert_true(
    report.actions.iter().all(a => a.action == Kept && a.reason == UnderBudget),
  )
}

///|
test "empty conversation" {
  let (out, report) = run([], 10)
  assert_eq(out, [])
  assert_eq(report.tokens_before, 3)
  assert_true(!report.triggered)
}

///|
fn expect_invalid_config(
  budget : Int,
  config : @moon_convo.Config,
) -> Unit raise {
  try run(five_rounds(), budget, config~) catch {
    @moon_convo.InvalidConfig(_) => ()
    e => fail("unexpected \{e}")
  } noraise {
    _ => fail("expected InvalidConfig")
  }
}

///|
test "invalid config" {
  let d = @moon_convo.Config::default()
  expect_invalid_config(1000, { ..d, low_water_pct: 80, high_water_pct: 70, })
  expect_invalid_config(1000, { ..d, low_water_pct: 0, })
  expect_invalid_config(1000, { ..d, high_water_pct: 101, })
  expect_invalid_config(1000, { ..d, keep_recent_units: -1, })
  expect_invalid_config(0, d)
}

///|
test "invalid conversation is rejected" {
  let ms = five_rounds()
  ms.remove(3) |> ignore // drop t1, leaving c1 orphaned
  try run(ms, 100) catch {
    @moon_convo.Invalid(OrphanToolCall("a1", "c1")) => ()
    e => fail("unexpected \{e}")
  } noraise {
    _ => fail("expected Invalid")
  }
}

///|
test "only system over budget" {
  try run([sys("s", words(200)), user("u", "hi")], 50) catch {
    @moon_convo.ProtectedExceedsBudget(protected_tokens~, budget~) => {
      assert_eq(protected_tokens, 3 + 8 + 200)
      assert_eq(budget, 50)
    }
    e => fail("unexpected \{e}")
  } noraise {
    _ => fail("expected ProtectedExceedsBudget")
  }
}

///|
test "fold old tool results only" {
  let ms = five_rounds()
  let (out, report) = run(ms, 4700)
  assert_true(report.triggered)
  assert_eq(report.budget, 4700)
  assert_eq(report.target, 3290)
  assert_eq(action_of(report, "t1"), (Folded, OldToolResult))
  assert_eq(action_of(report, "t2"), (Folded, OldToolResult))
  assert_eq(action_of(report, "t3"), (Kept, RecentToolRound))
  assert_eq(action_of(report, "t4"), (Kept, RecentToolRound))
  assert_eq(action_of(report, "t5"), (Kept, RecentToolRound))
  assert_eq(action_of(report, "a1"), (Kept, UnderBudget))
  assert_eq(action_of(report, "a2"), (Kept, RecentUnit))
  assert_eq(action_of(report, "s"), (Kept, System))
  assert_eq(action_of(report, "u"), (Kept, LastUser))
  assert_eq(out.length(), ms.length())
  assert_eq(out[3].text(), @moon_convo.fold_placeholder(Zh, "read_file", 1000))
  assert_eq(
    out[3].text(),
    "[已省略：read_file 的结果，原长约 1000 tokens]",
  )
  assert_eq(report.first_modified_index, Some(3))
  assert_eq(
    report.tokens_after,
    @moon_convo.count_conversation(out, estimator()),
  )
  assert_true(report.tokens_after <= report.target)
}

///|
test "fold placeholder in English" {
  let config = { ..@moon_convo.Config::default(), lang: En, }
  let (out, _) = run(five_rounds(), 4700, config~)
  assert_eq(
    out[3].text(),
    "[omitted: result of read_file, originally ~1000 tokens]",
  )
}

///|
test "fold stops at target" {
  let config = { ..@moon_convo.Config::default(), low_water_pct: 90, }
  let (_, report) = run(five_rounds(), 5000, config~)
  assert_eq(action_of(report, "t1"), (Folded, OldToolResult))
  assert_eq(action_of(report, "t2"), (Kept, UnderBudget))
}

///|
test "fold skips when placeholder is not shorter" {
  let ms = [sys("s", "be brief"), user("u", "fix the bug")]
  ms.append(round(1, 1))
  for k in 2..<=5 {
    ms.append(round(k, 1000))
  }
  let config = { ..@moon_convo.Config::default(), low_water_pct: 90, }
  let (_, report) = run(ms, 4100, config~)
  assert_eq(action_of(report, "t1"), (Kept, UnderBudget))
  assert_eq(action_of(report, "t2"), (Folded, OldToolResult))
}

///|
test "pinned tool result is not folded" {
  let ms = five_rounds()
  ms[3] = pin(ms[3])
  let (out, report) = run(ms, 4700)
  assert_eq(action_of(report, "t1"), (Kept, Pinned))
  assert_eq(out[3], ms[3])
  assert_eq(action_of(report, "t2"), (Folded, OldToolResult))
}

///|
fn say(id : String, text : String) -> @moon_convo.Message {
  { id, pinned: false, body: Assistant(content=text, tool_calls=[]), }
}

///|
fn ids(ms : Array[@moon_convo.Message]) -> Array[String] {
  ms.map(m => m.id)
}

///|
test "drop oldest units first" {
  let ms = [sys("s", "be brief")]
  for k in 1..<=5 {
    ms.push(user("q\{k}", words(300)))
    ms.push(say("r\{k}", words(300)))
  }
  let (out, report) = run(ms, 2400)
  for id in ["q1", "r1", "q2", "r2", "q3"] {
    assert_eq(action_of(report, id), (Dropped, OldestUnit))
  }
  assert_eq(action_of(report, "r3"), (Kept, UnderBudget))
  assert_eq(action_of(report, "q4"), (Kept, RecentUnit))
  assert_eq(action_of(report, "q5"), (Kept, LastUser))
  assert_eq(action_of(report, "s"), (Kept, System))
  assert_eq(ids(out), ["s", "r3", "q4", "r4", "q5", "r5"])
  assert_eq(report.first_modified_index, Some(1))
  assert_true(report.tokens_after <= report.target)
}

///|
test "tool exchange is dropped whole and long results truncated" {
  let (out, report) = run(five_rounds(), 1500)
  assert_eq(action_of(report, "a1"), (Dropped, OldestUnit))
  assert_eq(action_of(report, "t1"), (Dropped, OldestUnit))
  assert_eq(action_of(report, "a2"), (Kept, RecentUnit))
  assert_eq(action_of(report, "t2"), (Folded, OldToolResult))
  assert_eq(action_of(report, "t3"), (Truncated, TooLong))
  @moon_convo.validate(out)
  assert_true(report.tokens_after <= 1500)
  assert_eq(
    report.tokens_after,
    @moon_convo.count_conversation(out, estimator()),
  )
}

///|
test "last user message is kept even outside recent units" {
  let ms = [sys("s", "be brief"), user("u", "refactor everything")]
  for k in 1..<=10 {
    ms.append(round(k, 200))
  }
  let (out, report) = run(ms, 1500)
  assert_eq(action_of(report, "u"), (Kept, LastUser))
  assert_eq(action_of(report, "a1"), (Dropped, OldestUnit))
  assert_true(ids(out).contains("u"))
}

///|
test "unit with a pinned message is not dropped" {
  let ms = five_rounds()
  ms[2] = pin(ms[2])
  let (out, report) = run(ms, 1500)
  assert_eq(action_of(report, "a1"), (Kept, Pinned))
  assert_true(ids(out).contains("t1"))
  @moon_convo.validate(out)
}

///|
test "truncate an overlong message" {
  let (out, report) = run([sys("s", "be brief"), user("u", words(5000))], 1000)
  assert_eq(action_of(report, "u"), (Truncated, TooLong))
  let text = out[1].text()
  assert_true(text.contains("…[已截断约"))
  assert_true(text.has_prefix("abc"))
  assert_true(text.has_suffix("abc"))
  assert_true(report.tokens_after <= report.target)
}

///|
test "truncation never splits an emoji" {
  let sb = StringBuilder()
  for _ in 0..<600 {
    sb.write_string("😀")
  }
  let config = { ..@moon_convo.Config::default(), lang: En, }
  let (out, _) = run([user("u", sb.to_string())], 300, config~)
  let text = out[0].text()
  assert_true(text.contains("…[truncated ~"))
  assert_true(text.has_prefix("😀") && text.has_suffix("😀"))
  for c in text {
    assert_true(c.to_int() < 0xD800 || c.to_int() > 0xDFFF)
  }
}

///|
test "truncate_text" {
  let t = words(1000)
  let cut = @moon_convo.truncate_text(t, 100, estimator(), En)
  assert_true(@moon_convo.TokenCounter::count_text(estimator(), cut) <= 100)
  assert_true(cut.contains("…[truncated ~"))
  assert_eq(@moon_convo.truncate_text("short", 100, estimator(), En), "short")
}

///|
test "cannot fit when irreducible parts exceed the budget" {
  let call : @moon_convo.ToolCall = {
    id: "c1",
    name: "write_file",
    arguments: words(3000),
  }
  let ms : Array[@moon_convo.Message] = [
    sys("s", "be brief"),
    user("u", "go"),
    { id: "a1", pinned: false, body: Assistant(content="", tool_calls=[call]), },
    { id: "t1", pinned: false, body: Tool(tool_call_id="c1", content="ok"), },
  ]
  try run(ms, 500) catch {
    @moon_convo.CannotFit(tokens~, budget~) => {
      assert_eq(budget, 500)
      assert_true(tokens > 500)
    }
    e => fail("unexpected \{e}")
  } noraise {
    _ => fail("expected CannotFit")
  }
}
