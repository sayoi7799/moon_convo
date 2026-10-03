///|
/// One function call requested by an assistant message.
pub(all) struct ToolCall {
  id : String
  name : String
  /// Raw argument string, usually JSON. Never modified by trimming.
  arguments : String
} derive(Eq, Debug)

///|
/// Role and payload of a message. Putting both in one enum makes states such
/// as "a tool message without a tool_call_id" impossible to construct.
pub(all) enum Body {
  System(String)
  User(String)
  Assistant(content~ : String, tool_calls~ : Array[ToolCall])
  Tool(tool_call_id~ : String, content~ : String)
} derive(Eq, Debug)

///|
/// A vendor-neutral chat message with a stable id.
pub(all) struct Message {
  id : String
  /// Pinned messages are never dropped, folded or truncated.
  pinned : Bool
  body : Body
} derive(Eq, Debug)

///|
/// The OpenAI-style role name: `system`, `user`, `assistant` or `tool`.
pub fn Message::role_name(self : Message) -> String {
  match self.body {
    System(_) => "system"
    User(_) => "user"
    Assistant(..) => "assistant"
    Tool(..) => "tool"
  }
}

///|
/// The text content of the message, whatever its role.
pub fn Message::text(self : Message) -> String {
  match self.body {
    System(s) | User(s) => s
    Assistant(content~, ..) | Tool(content~, ..) => content
  }
}
