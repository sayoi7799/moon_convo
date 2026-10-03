///|
fn msgs(src : String) -> Array[@moon_convo.Message] {
  @moon_convo.parse_messages(src) catch {
    e => abort(e.to_repr().to_string())
  }
}

///|
fn expect_invalid(
  src : String,
  expected : @moon_convo.ValidationError,
) -> Unit raise {
  try @moon_convo.validate(msgs(src)) catch {
    e => assert_eq(e, expected)
  } noraise {
    _ => fail("expected \{expected.to_repr()}")
  }
}

///|
test "groups parallel tool calls into one unit" {
  let src =
    #|[{"role": "system", "content": "s"},
    #| {"role": "user", "content": "u"},
    #| {"role": "assistant", "content": null, "tool_calls": [
    #|   {"id": "c1", "function": {"name": "a", "arguments": "{}"}},
    #|   {"id": "c2", "function": {"name": "b", "arguments": "{}"}}]},
    #| {"role": "tool", "tool_call_id": "c2", "content": "r2"},
    #| {"role": "tool", "tool_call_id": "c1", "content": "r1"},
    #| {"role": "assistant", "content": "done"}]
  let units = @moon_convo.group_units(msgs(src))
  assert_eq(units, [
    Single(0),
    Single(1),
    ToolExchange(assistant=2, results=[3, 4]),
    Single(5),
  ])
  assert_eq(units[2].start(), 2)
  assert_eq(units[2].end(), 4)
  assert_eq(units[2].indices(), [2, 3, 4])
}

///|
test "empty conversation has no units" {
  assert_eq(@moon_convo.group_units([]), [])
}

///|
test "orphan tool call" {
  let src =
    #|[{"role": "assistant", "content": null, "tool_calls": [
    #|   {"id": "c1", "function": {"name": "a", "arguments": "{}"}},
    #|   {"id": "c2", "function": {"name": "b", "arguments": "{}"}}]},
    #| {"role": "tool", "tool_call_id": "c1", "content": "r1"},
    #| {"role": "user", "content": "u"}]
  expect_invalid(src, OrphanToolCall("m0", "c2"))
}

///|
test "orphan tool call at end of conversation" {
  let src =
    #|[{"role": "assistant", "content": null, "tool_calls": [
    #|   {"id": "c1", "function": {"name": "a", "arguments": "{}"}}]}]
  expect_invalid(src, OrphanToolCall("m0", "c1"))
}

///|
test "orphan tool result" {
  let src =
    #|[{"role": "user", "content": "u"},
    #| {"role": "tool", "tool_call_id": "zz", "content": "r"}]
  expect_invalid(src, OrphanToolResult("m1", "zz"))
}

///|
test "duplicate tool call id" {
  let src =
    #|[{"role": "assistant", "content": null, "tool_calls": [
    #|   {"id": "c1", "function": {"name": "a", "arguments": "{}"}}]},
    #| {"role": "tool", "tool_call_id": "c1", "content": "r"},
    #| {"role": "assistant", "content": null, "tool_calls": [
    #|   {"id": "c1", "function": {"name": "a", "arguments": "{}"}}]},
    #| {"role": "tool", "tool_call_id": "c1", "content": "r"}]
  expect_invalid(src, DuplicateToolCallId("m2", "c1"))
}

///|
test "duplicate tool result" {
  let src =
    #|[{"role": "assistant", "content": null, "tool_calls": [
    #|   {"id": "c1", "function": {"name": "a", "arguments": "{}"}}]},
    #| {"role": "tool", "tool_call_id": "c1", "content": "r"},
    #| {"role": "tool", "tool_call_id": "c1", "content": "r again"}]
  expect_invalid(src, DuplicateToolResult("m2", "c1"))
}

///|
test "tool result out of place" {
  let src =
    #|[{"role": "assistant", "content": null, "tool_calls": [
    #|   {"id": "c1", "function": {"name": "a", "arguments": "{}"}}]},
    #| {"role": "user", "content": "interrupt"},
    #| {"role": "tool", "tool_call_id": "c1", "content": "late"}]
  expect_invalid(src, ToolResultOutOfPlace("m2", "c1"))
}

///|
test "duplicate message id" {
  let src =
    #|[{"id": "x", "role": "user", "content": "a"},
    #| {"id": "x", "role": "user", "content": "b"}]
  expect_invalid(src, DuplicateMessageId("x"))
}
