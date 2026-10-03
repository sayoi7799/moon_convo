///|
/// An indivisible group of messages. Named `AtomicUnit` rather than `Unit` to
/// avoid shadowing MoonBit's built-in `Unit` type.
pub(all) enum AtomicUnit {
  /// A system, user, or tool-free assistant message.
  Single(Int)
  /// An assistant message with tool calls plus all of its tool results, which
  /// directly follow it. Indices refer to the message array.
  ToolExchange(assistant~ : Int, results~ : Array[Int])
} derive(Eq, Debug)

///|
/// First message index of the unit.
pub fn AtomicUnit::start(self : AtomicUnit) -> Int {
  match self {
    Single(i) => i
    ToolExchange(assistant~, ..) => assistant
  }
}

///|
/// Last message index of the unit (inclusive).
pub fn AtomicUnit::end(self : AtomicUnit) -> Int {
  match self {
    Single(i) => i
    ToolExchange(assistant~, results~) => assistant + results.length()
  }
}

///|
/// All message indices of the unit, in order.
pub fn AtomicUnit::indices(self : AtomicUnit) -> Array[Int] {
  Array::makei(self.end() - self.start() + 1, i => self.start() + i)
}

///|
/// Why a message list cannot be sent to a model as-is.
pub(all) suberror ValidationError {
  /// (assistant message id, call id): the call has no result.
  OrphanToolCall(String, String)
  /// (tool message id, call id): no assistant made this call.
  OrphanToolResult(String, String)
  /// (assistant message id, call id): the call id was already used.
  DuplicateToolCallId(String, String)
  /// (tool message id, call id): the call already has a result.
  DuplicateToolResult(String, String)
  /// (tool message id, call id): the result does not directly follow its call.
  ToolResultOutOfPlace(String, String)
  /// The message id is used twice.
  DuplicateMessageId(String)
} derive(Eq, Debug)

///|
/// Checks that every tool call has exactly one result directly after its
/// assistant message, and that message ids are unique. Reports the first
/// problem in message order.
pub fn validate(messages : Array[Message]) -> Unit raise ValidationError {
  group_units(messages) |> ignore
}

///|
/// Validates the messages and splits them into atomic units, in order.
pub fn group_units(
  messages : Array[Message],
) -> Array[AtomicUnit] raise ValidationError {
  // Where each call's result lives, to tell "missing" from "misplaced".
  let result_at : Map[String, String] = Map([])
  let all_calls : Set[String] = Set([])
  for m in messages {
    match m.body {
      Tool(tool_call_id~, ..) if !result_at.contains(tool_call_id) =>
        result_at[tool_call_id] = m.id
      Assistant(tool_calls~, ..) => tool_calls.each(c => all_calls.add(c.id))
      _ => ()
    }
  }
  let seen_ids : Set[String] = Set([])
  let seen_calls : Set[String] = Set([])
  let answered : Set[String] = Set([])
  let units = []
  // The tool exchange currently open: its assistant index, owner id, results
  // so far, and calls still waiting for a result.
  let mut open : (Int, String, Array[Int], Array[String])? = None
  fn close() raise ValidationError {
    if open is Some((assistant, owner, results, pending)) {
      for call in pending {
        match result_at.get(call) {
          Some(tool_id) => raise ToolResultOutOfPlace(tool_id, call)
          None => raise OrphanToolCall(owner, call)
        }
      }
      units.push(ToolExchange(assistant~, results~))
      open = None
    }
  }

  for i, m in messages {
    if seen_ids.contains(m.id) {
      raise DuplicateMessageId(m.id)
    }
    seen_ids.add(m.id)
    match m.body {
      Tool(tool_call_id~, ..) => {
        if !all_calls.contains(tool_call_id) {
          raise OrphanToolResult(m.id, tool_call_id)
        }
        if answered.contains(tool_call_id) {
          raise DuplicateToolResult(m.id, tool_call_id)
        }
        guard open is Some((_, _, results, pending)) &&
          pending.search(tool_call_id) is Some(k) else {
          raise ToolResultOutOfPlace(m.id, tool_call_id)
        }
        pending.remove(k) |> ignore
        results.push(i)
        answered.add(tool_call_id)
      }
      Assistant(tool_calls~, ..) if !tool_calls.is_empty() => {
        close()
        let pending = []
        for c in tool_calls {
          if seen_calls.contains(c.id) {
            raise DuplicateToolCallId(m.id, c.id)
          }
          seen_calls.add(c.id)
          pending.push(c.id)
        }
        open = Some((i, m.id, [], pending))
      }
      _ => {
        close()
        units.push(Single(i))
      }
    }
  }
  close()
  units
}
