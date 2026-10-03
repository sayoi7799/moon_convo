// Scenario tests: a conversation in OpenAI JSON, a budget, and the expected
// action for every message id. `<<n>>` in a JSON string expands to `n` tokens
// of filler for the default estimator. Token arithmetic for each budget is
// written next to the case.

///|
fn expand(src : String) -> String {
  let mut s = src
  for n in [300, 500, 1000, 2000, 5000] {
    s = s.replace_all(old="<<\{n}>>", new=words(n))
  }
  s
}

///|
fn check_case(
  src : String,
  budget : Int,
  expected : Array[(String, @moon_convo.Action)],
) -> @moon_convo.TrimReport raise {
  let ms = @moon_convo.parse_messages(expand(src))
  let (out, report) = @moon_convo.trim(ms, budget, estimator())
  assert_eq(report.actions.map(a => (a.id, a.action)), expected)
  @moon_convo.validate(out)
  assert_true(report.tokens_after <= budget)
  report
}

///|
/// Conversation total 4185 tokens:
/// s 16, u1 13, a1 71 (3 calls × 21), t1..t3 1010 each, a2 12, u2 12,
/// three single-call rounds (29 + 310), af 11, plus 3 overhead. Call ids
/// such as `c1` mix letters and digits, so each costs 2.
/// A folded 1000-token result costs 37, saving 973.
let parallel_calls : String =
  #|[{"id": "s", "role": "system", "content": "You are a coding agent."},
  #| {"id": "u1", "role": "user", "content": "Find the bug."},
  #| {"id": "a1", "role": "assistant", "content": null, "tool_calls": [
  #|   {"id": "c1", "type": "function", "function": {"name": "read_file", "arguments": "{}"}},
  #|   {"id": "c2", "type": "function", "function": {"name": "read_file", "arguments": "{}"}},
  #|   {"id": "c3", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}]},
  #| {"id": "t1", "role": "tool", "tool_call_id": "c1", "content": "<<1000>>"},
  #| {"id": "t2", "role": "tool", "tool_call_id": "c2", "content": "<<1000>>"},
  #| {"id": "t3", "role": "tool", "tool_call_id": "c3", "content": "<<1000>>"},
  #| {"id": "a2", "role": "assistant", "content": "Found it."},
  #| {"id": "u2", "role": "user", "content": "Now fix it."},
  #| {"id": "a4", "role": "assistant", "content": null, "tool_calls": [
  #|   {"id": "c4", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}]},
  #| {"id": "t4", "role": "tool", "tool_call_id": "c4", "content": "<<300>>"},
  #| {"id": "a5", "role": "assistant", "content": null, "tool_calls": [
  #|   {"id": "c5", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}]},
  #| {"id": "t5", "role": "tool", "tool_call_id": "c5", "content": "<<300>>"},
  #| {"id": "a6", "role": "assistant", "content": null, "tool_calls": [
  #|   {"id": "c6", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}]},
  #| {"id": "t6", "role": "tool", "tool_call_id": "c6", "content": "<<300>>"},
  #| {"id": "af", "role": "assistant", "content": "Fixed."}]

///|
test "case: parallel tool results are folded together" {
  // target 1400: folding t1, t2, t3 gives 4185 - 3 × 973 = 1266.
  let report = check_case(parallel_calls, 2000, [
    ("s", Kept),
    ("u1", Kept),
    ("a1", Kept),
    ("t1", Folded),
    ("t2", Folded),
    ("t3", Folded),
    ("a2", Kept),
    ("u2", Kept),
    ("a4", Kept),
    ("t4", Kept),
    ("a5", Kept),
    ("t5", Kept),
    ("a6", Kept),
    ("t6", Kept),
    ("af", Kept),
  ])
  assert_eq(report.tokens_after, 1266)
  assert_eq(report.first_modified_index, Some(3))
}

///|
test "case: parallel tool round is dropped as one unit" {
  // target 1190: folds give 1266; dropping u1 gives 1253; dropping the
  // whole round (71 + 3 × 37) gives 1071.
  let report = check_case(parallel_calls, 1700, [
    ("s", Kept),
    ("u1", Dropped),
    ("a1", Dropped),
    ("t1", Dropped),
    ("t2", Dropped),
    ("t3", Dropped),
    ("a2", Kept),
    ("u2", Kept),
    ("a4", Kept),
    ("t4", Kept),
    ("a5", Kept),
    ("t5", Kept),
    ("a6", Kept),
    ("t6", Kept),
    ("af", Kept),
  ])
  assert_eq(report.tokens_after, 1071)
  assert_eq(report.first_modified_index, Some(1))
}

///|
test "case: consecutive tool rounds" {
  // Total 3261: s 11, u 13, six rounds of 29 + 510. A folded 500-token
  // result costs 36, saving 474. target 1750: three folds give 1839,
  // dropping round 1 (65) gives 1774, round 2 gives 1709.
  let src =
    #|[{"id": "s", "role": "system", "content": "Agent."},
    #| {"id": "u", "role": "user", "content": "Run the tests."},
    #| {"id": "a1", "role": "assistant", "content": null, "tool_calls": [{"id": "c1", "function": {"name": "read_file", "arguments": "{}"}}]},
    #| {"id": "t1", "role": "tool", "tool_call_id": "c1", "content": "<<500>>"},
    #| {"id": "a2", "role": "assistant", "content": null, "tool_calls": [{"id": "c2", "function": {"name": "read_file", "arguments": "{}"}}]},
    #| {"id": "t2", "role": "tool", "tool_call_id": "c2", "content": "<<500>>"},
    #| {"id": "a3", "role": "assistant", "content": null, "tool_calls": [{"id": "c3", "function": {"name": "read_file", "arguments": "{}"}}]},
    #| {"id": "t3", "role": "tool", "tool_call_id": "c3", "content": "<<500>>"},
    #| {"id": "a4", "role": "assistant", "content": null, "tool_calls": [{"id": "c4", "function": {"name": "read_file", "arguments": "{}"}}]},
    #| {"id": "t4", "role": "tool", "tool_call_id": "c4", "content": "<<500>>"},
    #| {"id": "a5", "role": "assistant", "content": null, "tool_calls": [{"id": "c5", "function": {"name": "read_file", "arguments": "{}"}}]},
    #| {"id": "t5", "role": "tool", "tool_call_id": "c5", "content": "<<500>>"},
    #| {"id": "a6", "role": "assistant", "content": null, "tool_calls": [{"id": "c6", "function": {"name": "read_file", "arguments": "{}"}}]},
    #| {"id": "t6", "role": "tool", "tool_call_id": "c6", "content": "<<500>>"}]
  let report = check_case(src, 2500, [
    ("s", Kept),
    ("u", Kept),
    ("a1", Dropped),
    ("t1", Dropped),
    ("a2", Dropped),
    ("t2", Dropped),
    ("a3", Kept),
    ("t3", Folded),
    ("a4", Kept),
    ("t4", Kept),
    ("a5", Kept),
    ("t5", Kept),
    ("a6", Kept),
    ("t6", Kept),
  ])
  assert_eq(report.tokens_after, 1709)
}

///|
test "case: overlong single message is truncated" {
  // Total 5031: s 11, u 5008, a 9. Every unit is recent, so only
  // truncation can help.
  let src =
    #|[{"id": "s", "role": "system", "content": "Agent."},
    #| {"id": "u", "role": "user", "content": "<<5000>>"},
    #| {"id": "a", "role": "assistant", "content": "ok"}]
  let report = check_case(src, 2000, [
    ("s", Kept),
    ("u", Truncated),
    ("a", Kept),
  ])
  assert_true(report.tokens_after <= report.target)
}

///|
test "case: system alone exceeds the budget" {
  let src =
    #|[{"id": "s", "role": "system", "content": "<<2000>>"},
    #| {"id": "u", "role": "user", "content": "hi"}]
  try check_case(src, 1000, []) catch {
    @moon_convo.ProtectedExceedsBudget(protected_tokens~, budget~) => {
      assert_eq(protected_tokens, 3 + 2008)
      assert_eq(budget, 1000)
    }
    e => fail("unexpected \{e}")
  } noraise {
    _ => fail("expected ProtectedExceedsBudget")
  }
}

///|
test "case: empty conversation" {
  let report = check_case("[]", 100, [])
  assert_true(!report.triggered)
}

///|
test "case: mixed Chinese, English and code under budget" {
  let src =
    #|[{"id": "s", "role": "system", "content": "你是一个编程助手。"},
    #| {"id": "u", "role": "user", "content": "请修复 `fn add(a: Int) -> Int { a + 1 }` 里的 bug"},
    #| {"id": "a", "role": "assistant", "content": "已修复：返回值应为 a + 2。"}]
  let report = check_case(src, 1000, [("s", Kept), ("u", Kept), ("a", Kept)])
  assert_true(!report.triggered)
}
