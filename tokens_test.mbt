///|
fn est(s : String) -> Int {
  @moon_convo.TokenCounter::count_text(
    @moon_convo.ConservativeEstimator::new(),
    s,
  )
}

///|
test "ascii words and digits" {
  assert_eq(est(""), 0)
  assert_eq(est("hello"), 2)
  assert_eq(est("hello world"), 4)
  assert_eq(est("12345"), 2)
  assert_eq(est("a+b"), 3)
}

///|
test "cjk counts 1.2 per char rounded up" {
  assert_eq(est("你好世界吗"), 6)
  assert_eq(est("你好"), 3)
  assert_eq(est("こんにちは"), 6)
}

///|
test "whitespace runs" {
  assert_eq(est("a\n\n  b"), 3)
  assert_eq(est("a     b"), 4)
}

///|
test "other non-ascii counts 2 per code point" {
  assert_eq(est("é"), 2)
  assert_eq(est("😀"), 2)
}

///|
test "message overheads" {
  let c = @moon_convo.ConservativeEstimator::new()
  let user : @moon_convo.Message = {
    id: "u",
    pinned: false,
    body: User("hello"),
  }
  assert_eq(@moon_convo.TokenCounter::count_message(c, user), 10)
  let call : @moon_convo.ToolCall = { id: "c1", name: "ls", arguments: "{}", }
  let asst : @moon_convo.Message = {
    id: "a",
    pinned: false,
    body: Assistant(content="", tool_calls=[call]),
  }
  assert_eq(@moon_convo.TokenCounter::count_message(c, asst), 24)
  let tool : @moon_convo.Message = {
    id: "t",
    pinned: false,
    body: Tool(tool_call_id="c1", content="ok"),
  }
  assert_eq(@moon_convo.TokenCounter::count_message(c, tool), 10)
}

///|
test "conversation overhead" {
  let c = @moon_convo.ConservativeEstimator::new()
  assert_eq(@moon_convo.count_conversation([], c), 3)
  let user : @moon_convo.Message = {
    id: "u",
    pinned: false,
    body: User("hello"),
  }
  assert_eq(@moon_convo.count_conversation([user, user], c), 23)
}

///|
struct CharCounter {}

///|
impl @moon_convo.TokenCounter for CharCounter with fn count_text(_, s) {
  s.length()
}

///|
test "custom counter inherits default message overhead" {
  let user : @moon_convo.Message = {
    id: "u",
    pinned: false,
    body: User("abc"),
  }
  assert_eq(@moon_convo.TokenCounter::count_message(CharCounter::{ }, user), 11)
}

///|
test "punctuation splits runs" {
  assert_eq(est("hello+world"), 5)
  assert_eq(est("x = 1"), 3)
}
