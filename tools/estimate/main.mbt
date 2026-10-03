///|
/// Prints the default estimator's count for each command-line argument, one
/// per line. Used by `tools/calibrate.py`.
fn main {
  let est = @convo.ConservativeEstimator::new()
  for arg in @env.args()[1:] {
    println(@convo.TokenCounter::count_text(est, arg))
  }
}
