# frozen_string_literal: true

require_relative "../corkscrews"
require_relative "native"

if ENV["CORKSCREWS_PROFILE"] == "1"
  Corkscrews::Native.install_hooks!

  if ENV["CORKSCREWS_PRIMITIVES"] == "1"
    require_relative "primitives"
    Corkscrews::Primitives.install!
  end

  output = ENV.fetch("CORKSCREWS_OUTPUT")
  Corkscrews.start!(
    output: output,
    run_id: ENV["CORKSCREWS_RUN_ID"],
    repeat_index: ENV["CORKSCREWS_REPEAT_INDEX"],
    sample_period_ms: ENV["CORKSCREWS_SAMPLE_PERIOD_MS"]
  )

  at_exit do
    Corkscrews.stop!
  end
end
