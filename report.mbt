///|
/// What happened to one input message.
pub(all) enum Action {
  Kept
  /// Tool result replaced by a one-line placeholder.
  Folded
  /// Removed together with the rest of its atomic unit.
  Dropped
  /// Content cut in the middle, head and tail kept.
  Truncated
} derive(Eq, Debug)

///|
/// Why the action was taken.
pub(all) enum Reason {
  /// Kept: system messages are never touched.
  System
  /// Kept: pinned, or in the same atomic unit as a pinned message.
  Pinned
  /// Kept: in one of the most recent `keep_recent_units` units.
  RecentUnit
  /// Kept unfolded: in one of the most recent `keep_recent_tool_rounds` rounds.
  RecentToolRound
  /// Kept: the unit containing the last user message.
  LastUser
  /// Kept: no trimming needed, or the target was reached before this message.
  UnderBudget
  /// Folded: tool result outside the recent rounds.
  OldToolResult
  /// Dropped: oldest unprotected unit.
  OldestUnit
  /// Truncated: largest remaining message.
  TooLong
} derive(Eq, Debug)

///|
/// The fate of one input message.
pub(all) struct MessageAction {
  id : String
  /// Index in the input array.
  index : Int
  action : Action
  reason : Reason
  tokens_before : Int
  /// 0 when dropped.
  tokens_after : Int
} derive(Eq, Debug)

///|
/// Everything `trim` did, one action per input message, in input order.
pub(all) struct TrimReport {
  /// Whether the high watermark was exceeded and trimming ran.
  triggered : Bool
  budget : Int
  /// budget × low_water_pct / 100.
  target : Int
  tokens_before : Int
  tokens_after : Int
  /// Input index of the first message that was changed or removed. A provider
  /// prompt cache is invalid from this position on; None means fully reusable.
  first_modified_index : Int?
  actions : Array[MessageAction]
} derive(Eq, Debug)

///|
/// Why trimming failed.
pub(all) suberror TrimError {
  /// The input breaks tool-call pairing or has duplicate ids.
  Invalid(ValidationError)
  InvalidConfig(String)
  /// System and pinned messages alone exceed the budget. They are never cut.
  ProtectedExceedsBudget(protected_tokens~ : Int, budget~ : Int)
  /// Every allowed step ran and the conversation is still over budget.
  CannotFit(tokens~ : Int, budget~ : Int)
} derive(Eq, Debug)
