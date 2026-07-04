# frozen_string_literal: true

require_relative "../support"

def native_call_work
  900.times.sum { |i| Integer.sqrt((i * i) + 7) }
end

iterations = CorkscrewsBench.iterations(500)
started = CorkscrewsBench.monotonic_ns
checksum = 0

iterations.times do
  checksum ^= native_call_work
  Corkscrews.progress(:work_done)
end

CorkscrewsBench.finish(progress: iterations, started_ns: started, checksum: checksum)
