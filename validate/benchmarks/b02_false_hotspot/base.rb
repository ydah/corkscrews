# frozen_string_literal: true

require_relative "../support"

def decoy_spin
  700.times.sum { |i| i * i }
end

iterations = CorkscrewsBench.iterations(300)
started = CorkscrewsBench.monotonic_ns
r, w = IO.pipe
delay = 0.0025
checksum = 0

producer = Thread.new do
  loop do
    sleep delay
    w.write("x")
  end
end

decoy = Thread.new do
  loop do
    checksum ^= decoy_spin
    Thread.pass
  end
end

begin
  iterations.times do
    r.read(1)
    Corkscrews.progress(:work_done)
  end
ensure
  producer.kill
  decoy.kill
  producer.join(0.1)
  decoy.join(0.1)
  r.close unless r.closed?
  w.close unless w.closed?
end

CorkscrewsBench.finish(progress: iterations, started_ns: started, checksum: checksum)
