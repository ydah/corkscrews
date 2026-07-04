# frozen_string_literal: true

require_relative "../support"

iterations = CorkscrewsBench.iterations(500)
started = CorkscrewsBench.monotonic_ns
checksum = 0

iterations.times do
  data = Array.new(400) { |i| "x#{i}" }
  checksum ^= data.length
  GC.start if (checksum % 17).zero?
  Corkscrews.progress(:work_done)
end

CorkscrewsBench.finish(progress: iterations, started_ns: started, checksum: checksum)
