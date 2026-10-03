// Property tests for the trim invariants (docs/design.md §7), driven by
// random legal conversations.

///|
/// A random legal conversation, kept as atomic units so shrinking can remove
/// whole units without breaking tool-call pairing.
struct Case {
  units : Array[Array[@moon_convo.Message]]
  budget : Int
} derive(Debug)

///|
fn Case::messages(self : Case) -> Array[@moon_convo.Message] {
  let out = []
  for u in self.units {
    out.append(u)
  }
  out
}

///|
let pieces : Array[String] = [
  "abc", "hello world", "你好世界", "上下文窗口", "fn main() { let x = 1 + 2 }",
  "😀", "\n", "    ", "x=1;", "Привет", "2026-10-03", "call_Xy7Qm2",
]

///|
fn rand(rs : @splitmix.RandomState, n : Int) -> Int {
  rs.next_uint(limit=n.reinterpret_as_uint()).reinterpret_as_int()
}

///|
fn gen_text(rs : @splitmix.RandomState, size : Int) -> String {
  let sb = StringBuilder()
  for _ in 0..<rand(rs, size * 8 + 1) {
    sb.write_string(pieces[rand(rs, pieces.length())])
    if rand(rs, 3) == 0 {
      sb.write_char(' ')
    }
  }
  sb.to_string()
}

///|
impl @quickcheck.Arbitrary for Case with fn arbitrary(size, rs) {
  let size = if size > 40 { 40 } else { size }
  let units : Array[Array[@moon_convo.Message]] = []
  let mut next_id = 0
  let mut next_call = 0
  fn msg(body : @moon_convo.Body) -> @moon_convo.Message {
    let m : @moon_convo.Message = {
      id: "m\{next_id}",
      pinned: rand(rs, 10) == 0,
      body,
    }
    next_id += 1
    m
  }

  if rand(rs, 5) != 0 {
    units.push([msg(System(gen_text(rs, 2)))])
  }
  for _ in 0..<rand(rs, size + 1) {
    match rand(rs, 3) {
      0 => units.push([msg(User(gen_text(rs, size)))])
      1 =>
        units.push([msg(Assistant(content=gen_text(rs, size), tool_calls=[]))])
      _ => {
        let calls : Array[@moon_convo.ToolCall] = []
        for _ in 0..<(1 + rand(rs, 4)) {
          calls.push({
            id: "c\{next_call}",
            name: ["read_file", "grep", "run_tests"][rand(rs, 3)],
            arguments: "{\"q\":\"\{gen_text(rs, 1)}\"}",
          })
          next_call += 1
        }
        let unit = [msg(Assistant(content=gen_text(rs, 1), tool_calls=calls))]
        // Results in a random order.
        let order = calls.copy()
        for i in 0..<order.length() {
          let j = i + rand(rs, order.length() - i)
          order.swap(i, j)
        }
        for c in order {
          unit.push(
            msg(Tool(tool_call_id=c.id, content=gen_text(rs, size * 2))),
          )
        }
        units.push(unit)
      }
    }
  }
  let draft = { units, budget: 0, }
  let total = @moon_convo.count_conversation(draft.messages(), estimator())
  let pct = 10 + rand(rs, 141)
  let budget = total * pct / 100
  { units, budget: if budget < 30 { 30 } else { budget }, }
}

///|
impl @quickcheck.Shrink for Case with fn shrink(self) {
  // Remove one unit at a time, newest first.
  let out = []
  for i = self.units.length() - 1; i >= 0; i = i - 1 {
    let units = self.units.copy()
    units.remove(i) |> ignore
    out.push({ ..self, units, })
  }
  out.iter()
}

///|
fn trim_case(
  c : Case,
) -> (Array[@moon_convo.Message], @moon_convo.TrimReport)? raise {
  let ms = c.messages()
  try @moon_convo.trim(ms, c.budget, estimator()) catch {
    ProtectedExceedsBudget(protected_tokens~, budget~) => {
      assert_true(protected_tokens > budget)
      None
    }
    CannotFit(tokens~, budget~) => {
      assert_true(tokens > budget)
      None
    }
    e => fail("unexpected error \{e.to_repr()}")
  } noraise {
    r => Some(r)
  }
}

///|
test "prop: output fits the budget or a budget error is returned" {
  @quickcheck.check(
    (c : Case) => {
      match trim_case(c) {
        None => true
        Some((out, report)) => {
          let real = @moon_convo.count_conversation(out, estimator())
          real <= c.budget && real == report.tokens_after
        }
      }
    },
    count=300,
    seed=1,
  )
}

///|
test "prop: no orphan tool calls or results" {
  @quickcheck.check(
    (c : Case) => {
      match trim_case(c) {
        None => true
        Some((out, _)) => {
          @moon_convo.validate(out)
          true
        }
      }
    },
    count=300,
    seed=2,
  )
}

///|
test "prop: system and pinned messages are kept unchanged" {
  @quickcheck.check(
    (c : Case) => {
      match trim_case(c) {
        None => true
        Some((out, _)) =>
          c
          .messages()
          .iter()
          .filter(m => m.pinned || m.body is System(_))
          .all(m => out.contains(m))
      }
    },
    count=300,
    seed=3,
  )
}

///|
test "prop: relative order is preserved" {
  @quickcheck.check(
    (c : Case) => {
      match trim_case(c) {
        None => true
        Some((out, _)) => {
          // Output ids form a subsequence of input ids.
          let input = c.messages()
          let mut j = 0
          for m in out {
            while j < input.length() && input[j].id != m.id {
              j += 1
            }
            if j == input.length() {
              return false
            }
            j += 1
          }
          true
        }
      }
    },
    count=300,
    seed=4,
  )
}

///|
test "prop: deterministic" {
  @quickcheck.check(
    (c : Case) => {
      // Results are kept as data so the two runs can be compared.
      let run = () => {
        let r : Result[_, @moon_convo.TrimError] = try
          @moon_convo.trim(c.messages(), c.budget, estimator()) |> Ok
        catch {
          e => Err(e)
        }
        r
      }
      run() == run()
    },
    count=300,
    seed=5,
  )
}

///|
test "prop: idempotent" {
  @quickcheck.check(
    (c : Case) => {
      match trim_case(c) {
        None => true
        Some((out, _)) => {
          let (again, _) = @moon_convo.trim(out, c.budget, estimator())
          again == out
        }
      }
    },
    count=300,
    seed=6,
  )
}
