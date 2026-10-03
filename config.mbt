///|
/// Language of the placeholder and truncation marker text.
pub(all) enum Lang {
  Zh
  En
} derive(Eq, Debug)

///|
/// Trimming knobs. Start from `Config::default()` and override fields.
pub(all) struct Config {
  /// Trim only when total tokens exceed budget × high_water_pct / 100.
  high_water_pct : Int
  /// When trimming, aim for budget × low_water_pct / 100.
  low_water_pct : Int
  /// Tool results of this many most recent tool rounds are never folded.
  keep_recent_tool_rounds : Int
  /// This many most recent atomic units are never dropped.
  keep_recent_units : Int
  /// Truncation never cuts a message's content below this many tokens.
  min_truncate_tokens : Int
  /// Language of placeholder and truncation marker text.
  lang : Lang
} derive(Eq, Debug)

///|
/// high 100%, low 70%, K = 3 tool rounds, N = 4 units, 64-token truncation
/// floor, Chinese placeholders.
pub fn Config::default() -> Config {
  {
    high_water_pct: 100,
    low_water_pct: 70,
    keep_recent_tool_rounds: 3,
    keep_recent_units: 4,
    min_truncate_tokens: 64,
    lang: Zh,
  }
}

///|
fn Config::check(self : Config, budget : Int) -> Unit raise TrimError {
  if budget <= 0 {
    raise InvalidConfig("budget must be positive, got \{budget}")
  }
  if !(0 < self.low_water_pct &&
    self.low_water_pct <= self.high_water_pct &&
    self.high_water_pct <= 100) {
    raise InvalidConfig(
      "need 0 < low_water_pct <= high_water_pct <= 100, got low \{self.low_water_pct}, high \{self.high_water_pct}",
    )
  }
  if self.keep_recent_tool_rounds < 0 ||
    self.keep_recent_units < 0 ||
    self.min_truncate_tokens < 0 {
    raise InvalidConfig(
      "keep_recent_tool_rounds, keep_recent_units and min_truncate_tokens must be >= 0",
    )
  }
}

///|
/// The one-line text that replaces a folded tool result.
pub fn fold_placeholder(
  lang : Lang,
  tool_name : String,
  tokens : Int,
) -> String {
  match lang {
    Zh => "[已省略：\{tool_name} 的结果，原长约 \{tokens} tokens]"
    En => "[omitted: result of \{tool_name}, originally ~\{tokens} tokens]"
  }
}

///|
/// Whether `text` is already a folded placeholder (in either language), so
/// folding is never applied twice.
fn is_placeholder(text : String) -> Bool {
  text.has_prefix("[已省略：") || text.has_prefix("[omitted: result of ")
}
