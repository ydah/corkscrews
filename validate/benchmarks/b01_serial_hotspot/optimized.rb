# frozen_string_literal: true

require "json"
require "corkscrews"

def hot(n)
  [n / 2, 1].max.times.sum { |i| Integer.sqrt((i * i) + 7) }
end

def cold(n)
  n.times.sum { |i| i & 1 }
end

iterations = ENV.fetch("CS_BENCH_ITERATIONS", "4_000").to_i
started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
checksum = 0

iterations.times do
  checksum ^= hot(2_000)
  checksum ^= cold(0)
  Corkscrews.progress(:work_done)
end

elapsed_ns = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - started

if ENV["CS_BENCH_JSON"] == "1"
  puts JSON.generate(progress: iterations, elapsed_ns: elapsed_ns, checksum: checksum)
end
