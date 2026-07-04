# frozen_string_literal: true

require "json"
require "corkscrews"

module CorkscrewsBench
  module_function

  def iterations(default)
    ENV.fetch("CS_BENCH_ITERATIONS", default.to_s).to_i
  end

  def monotonic_ns
    Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
  end

  def busy(iterations)
    total = 0
    iterations.times { |i| total += Integer.sqrt((i * i) + 7) }
    total
  end

  def finish(progress:, started_ns:, checksum: 0)
    elapsed_ns = monotonic_ns - started_ns
    return unless ENV["CS_BENCH_JSON"] == "1"

    puts JSON.generate(progress: progress, elapsed_ns: elapsed_ns, checksum: checksum)
  end
end
