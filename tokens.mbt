///|
/// Counts tokens. Implement `count_text` to plug in a real tokenizer; override
/// `count_message` too if your provider's per-message framing differs.
pub(open) trait TokenCounter {
  fn count_text(Self, String) -> Int
  fn count_message(Self, Message) -> Int = _
}

///|
/// Fixed cost of every message (role, separators).
pub let message_overhead : Int = 8

///|
/// Fixed cost of every tool call (type, wrapping JSON).
pub let tool_call_overhead : Int = 12

///|
/// Fixed cost of a whole conversation (priming the reply).
pub let conversation_overhead : Int = 3

///|
impl TokenCounter with fn count_message(self, m) {
  let text = self.count_text(m.text())
  let extra = match m.body {
    System(_) | User(_) => 0
    Assistant(tool_calls~, ..) => {
      let mut sum = 0
      for c in tool_calls {
        sum += tool_call_overhead +
          self.count_text(c.id) +
          self.count_text(c.name) +
          self.count_text(c.arguments)
      }
      sum
    }
    Tool(tool_call_id~, ..) => self.count_text(tool_call_id)
  }
  message_overhead + text + extra
}

///|
/// Total tokens of a conversation: `conversation_overhead` plus every message.
pub fn[C : TokenCounter] count_conversation(
  messages : Array[Message],
  counter : C,
) -> Int {
  let mut sum = conversation_overhead
  for m in messages {
    sum += counter.count_message(m)
  }
  sum
}

///|
/// The default estimator. It deliberately over-counts: see the README for the
/// per-character-class rules.
pub struct ConservativeEstimator {}

///|
pub fn ConservativeEstimator::new() -> ConservativeEstimator {
  ConservativeEstimator::{ }
}

///|
priv enum CharClass {
  Cjk
  AsciiAlnum
  AsciiPunct
  Space
  Other
} derive(Eq)

///|
fn classify(c : Char) -> CharClass {
  let u = c.to_int()
  if (u >= 'a' && u <= 'z') || (u >= 'A' && u <= 'Z') || (u >= '0' && u <= '9') {
    AsciiAlnum
  } else if c == ' ' || c == '\n' || c == '\t' || c == '\r' {
    Space
  } else if u < 0x80 {
    AsciiPunct
  } else if is_cjk(u) {
    Cjk
  } else {
    Other
  }
}

///|
fn is_cjk(u : Int) -> Bool {
  (u >= 0x3040 && u <= 0x30FF) || // kana
  (u >= 0x3400 && u <= 0x4DBF) || // CJK extension A
  (u >= 0x4E00 && u <= 0x9FFF) || // CJK unified
  (u >= 0xF900 && u <= 0xFAFF) || // CJK compatibility
  (u >= 0xAC00 && u <= 0xD7AF) || // hangul
  (u >= 0x20000 && u <= 0x2FFFF) // CJK extensions B+
}

///|
fn ceil_div(a : Int, b : Int) -> Int {
  (a + b - 1) / b
}

///|
/// What an ASCII letter/digit run looks like, collected while scanning it.
priv struct RunShape {
  mut letter : Bool
  mut digit : Bool
  mut lower : Bool
  /// An uppercase letter after the first character, as in `fileName`.
  mut inner_upper : Bool
}

///|
fn RunShape::new() -> RunShape {
  { letter: false, digit: false, lower: false, inner_upper: false, }
}

///|
fn RunShape::add(self : RunShape, c : Char, pos : Int) -> Unit {
  if c >= '0' && c <= '9' {
    self.digit = true
  } else {
    self.letter = true
    if c >= 'a' && c <= 'z' {
      self.lower = true
    } else if pos > 0 {
      self.inner_upper = true
    }
  }
}

///|
/// Mixed letters and digits, or camelCase: ids, hashes, base64. Real
/// tokenizers split these into short pieces.
fn RunShape::is_random(self : RunShape) -> Bool {
  (self.letter && self.digit) || (self.inner_upper && self.lower)
}

///|
fn run_tokens(
  class : CharClass,
  len : Int,
  first : Char,
  shape : RunShape,
) -> Int {
  match class {
    Cjk => ceil_div(len * 6, 5)
    AsciiAlnum =>
      if shape.is_random() {
        ceil_div(len * 2, 3)
      } else {
        ceil_div(len, 3)
      }
    // A single space merges into the following word in BPE tokenizers.
    Space => if len == 1 && first == ' ' { 0 } else { ceil_div(len, 4) }
    AsciiPunct => len
    Other => len * 2
  }
}

///|
pub impl TokenCounter for ConservativeEstimator with fn count_text(_, s) {
  let mut total = 0
  let mut run_class : CharClass? = None
  let mut run_len = 0
  let mut first = ' '
  let mut shape = RunShape::new()
  for c in s {
    let cls = classify(c)
    if run_class != Some(cls) {
      if run_class is Some(prev) {
        total += run_tokens(prev, run_len, first, shape)
      }
      run_class = Some(cls)
      run_len = 0
      first = c
      shape = RunShape::new()
    }
    if cls == AsciiAlnum {
      shape.add(c, run_len)
    }
    run_len += 1
  }
  if run_class is Some(prev) {
    total += run_tokens(prev, run_len, first, shape)
  }
  total
}
