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
