# frozen_string_literal: true

require_relative "../support"

iterations = CorkscrewsBench.iterations(500)
started = CorkscrewsBench.monotonic_ns
buffer = Array.new(40)
checksum = 0

iterations.times do
  buffer.each_index { |i| buffer[i] = i }
  checksum ^= buffer.length
  GC.start if (checksum % 101).zero?
  Corkscrews.progress(:work_done)
end

CorkscrewsBench.finish(progress: iterations, started_ns: started, checksum: checksum)
