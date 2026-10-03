///|
/// Raised when input is not a supported OpenAI-style message list.
pub(all) suberror DecodeError {
  DecodeError(String)
} derive(Eq, Debug)

///|
/// Parses JSON text and decodes it with `messages_from_json`.
pub fn parse_messages(src : String) -> Array[Message] raise DecodeError {
  let json = @json.parse(src) catch {
    e => raise DecodeError("invalid JSON: " + e.to_string())
  }
  messages_from_json(json)
}

///|
/// Decodes an array of OpenAI chat-format messages.
///
/// Extension fields: `id` (defaults to `m<index>`) and `pinned` (defaults to
/// false). Only string or null `content` is supported.
pub fn messages_from_json(json : Json) -> Array[Message] raise DecodeError {
  guard json is Array(items) else {
    raise DecodeError("expected a JSON array of messages")
  }
  let out = []
  for i, item in items {
    out.push(decode_message(item, i))
  }
  out
}

///|
fn decode_message(json : Json, index : Int) -> Message raise DecodeError {
  guard json is Object(obj) else {
    raise DecodeError("message \{index}: expected an object")
  }
  let id = match obj.get("id") {
    None | Some(Null) => "m\{index}"
    Some(String(s)) => s
    Some(_) => raise DecodeError("message \{index}: `id` must be a string")
  }
  let pinned = match obj.get("pinned") {
    None | Some(Null) | Some(False) => false
    Some(True) => true
    Some(_) => raise DecodeError("message \{id}: `pinned` must be a boolean")
  }
  let content = match obj.get("content") {
    None | Some(Null) => ""
    Some(String(s)) => s
    Some(_) =>
      raise DecodeError(
        "message \{id}: only string or null `content` is supported",
      )
  }
  let body : Body = match obj.get("role") {
    Some(String("system")) => System(content)
    Some(String("user")) => User(content)
    Some(String("assistant")) =>
      Assistant(
        content~,
        tool_calls=decode_tool_calls(obj.get("tool_calls"), id),
      )
    Some(String("tool")) =>
      match obj.get("tool_call_id") {
        Some(String(call_id)) => Tool(tool_call_id=call_id, content~)
        _ =>
          raise DecodeError("message \{id}: tool message needs `tool_call_id`")
      }
    Some(String(r)) =>
      raise DecodeError("message \{id}: unsupported role `\{r}`")
    _ => raise DecodeError("message \{id}: missing `role`")
  }
  { id, pinned, body, }
}

///|
fn decode_tool_calls(
  json : Json?,
  msg_id : String,
) -> Array[ToolCall] raise DecodeError {
  let items = match json {
    None | Some(Null) => return []
    Some(Array(items)) => items
    Some(_) =>
      raise DecodeError("message \{msg_id}: `tool_calls` must be an array")
  }
  items.map(item => {
    match item {
      {
        "id": String(id),
        "function": { "name": String(name), "arguments": String(arguments), .. },
        ..
      } => { id, name, arguments, }
      _ =>
        raise DecodeError(
          "message \{msg_id}: tool call needs `id`, `function.name`, `function.arguments`",
        )
    }
  })
}

///|
/// Encodes messages back to the OpenAI chat format, including `id` and
/// `pinned`, so the result can be decoded again.
pub fn messages_to_json(messages : Array[Message]) -> Json {
  Json::array(messages.map(message_to_json))
}

///|
fn message_to_json(m : Message) -> Json {
  let obj : Map[String, Json] = {
    "id": Json::string(m.id),
    "pinned": Json::boolean(m.pinned),
    "role": Json::string(m.role_name()),
    "content": Json::string(m.text()),
  }
  match m.body {
    Assistant(tool_calls~, ..) if !tool_calls.is_empty() =>
      obj["tool_calls"] = Json::array(
        tool_calls.map(c => {
          "id": Json::string(c.id),
          "type": "function",
          "function": {
            "name": Json::string(c.name),
            "arguments": Json::string(c.arguments),
          },
        }),
      )
    Tool(tool_call_id~, ..) => obj["tool_call_id"] = Json::string(tool_call_id)
    _ => ()
  }
  Json::object(obj)
}
