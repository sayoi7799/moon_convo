///|
test "decode basic roles" {
  let src =
    #|[
    #|  {"role": "system", "content": "be brief"},
    #|  {"role": "user", "content": "list files"},
    #|  {"role": "assistant", "content": null,
    #|   "tool_calls": [{"id": "c1", "type": "function",
    #|                   "function": {"name": "ls", "arguments": "{}"}}]},
    #|  {"role": "tool", "tool_call_id": "c1", "content": "a.txt"}
    #|]
  let ms = @moon_convo.parse_messages(src)
  assert_eq(ms.length(), 4)
  assert_eq(ms.map(m => m.id), ["m0", "m1", "m2", "m3"])
  assert_eq(ms.map(m => m.pinned), [false, false, false, false])
  assert_eq(ms.map(m => m.role_name()), ["system", "user", "assistant", "tool"])
  assert_eq(ms[0].body, System("be brief"))
  assert_eq(ms[3].body, Tool(tool_call_id="c1", content="a.txt"))
}

///|
test "decode explicit id and pinned" {
  let src =
    #|[{"id": "sys", "pinned": true, "role": "system", "content": "x"},
    #| {"role": "user", "content": "y"}]
  let ms = @moon_convo.parse_messages(src)
  assert_eq(ms[0].id, "sys")
  assert_true(ms[0].pinned)
  assert_eq(ms[1].id, "m1")
  assert_true(!ms[1].pinned)
}

///|
test "decode parallel tool calls with null content" {
  let src =
    #|[{"role": "assistant", "content": null, "tool_calls": [
    #|   {"id": "a", "type": "function", "function": {"name": "read_file", "arguments": "{\"path\":\"x\"}"}},
    #|   {"id": "b", "type": "function", "function": {"name": "grep", "arguments": "{}"}}]},
    #| {"role": "tool", "tool_call_id": "a", "content": ""},
    #| {"role": "tool", "tool_call_id": "b", "content": "hit"}]
  let ms = @moon_convo.parse_messages(src)
  guard ms[0].body is Assistant(content~, tool_calls~) else {
    fail("not assistant")
  }
  assert_eq(content, "")
  assert_eq(tool_calls.length(), 2)
  assert_eq(tool_calls[0], {
    id: "a",
    name: "read_file",
    arguments: "{\"path\":\"x\"}",
  })
  assert_eq(tool_calls[1].name, "grep")
  assert_eq(ms[1].text(), "")
}

///|
fn expect_decode_error(src : String) -> Unit raise {
  try @moon_convo.parse_messages(src) catch {
    @moon_convo.DecodeError(_) => ()
  } noraise {
    _ => fail("expected DecodeError for " + src)
  }
}

///|
test "decode errors" {
  let src =
    #|[{"role": "user", "content": [{"type": "text", "text": "hi"}]}]
  expect_decode_error(src)
  let src =
    #|[{"role": "developer", "content": "hi"}]
  expect_decode_error(src)
  let src =
    #|[{"role": "tool", "content": "orphan"}]
  expect_decode_error(src)
  let src =
    #|{"role": "user", "content": "hi"}
  expect_decode_error(src)
  expect_decode_error("not json")
}

///|
test "round trip" {
  let src =
    #|[{"id": "s", "pinned": true, "role": "system", "content": "sys"},
    #| {"role": "user", "content": "你好 world"},
    #| {"role": "assistant", "content": "thinking", "tool_calls": [
    #|   {"id": "c1", "type": "function", "function": {"name": "ls", "arguments": "{}"}}]},
    #| {"role": "tool", "tool_call_id": "c1", "content": "ok"},
    #| {"role": "assistant", "content": "done"}]
  let ms = @moon_convo.parse_messages(src)
  let again = @moon_convo.messages_from_json(@moon_convo.messages_to_json(ms))
  assert_eq(again, ms)
}
