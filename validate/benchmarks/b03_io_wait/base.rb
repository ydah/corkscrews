# frozen_string_literal: true

require_relative "../support"

iterations = CorkscrewsBench.iterations(240)
started = CorkscrewsBench.monotonic_ns
r, w = IO.pipe
delay = 0.002

server = Thread.new do
  loop do
    sleep delay
    w.write("x")
  end
end

begin
  iterations.times do
    r.read(1)
    Corkscrews.progress(:work_done)
  end
ensure
  server.kill
  server.join(0.1)
  r.close unless r.closed?
  w.close unless w.closed?
end

CorkscrewsBench.finish(progress: iterations, started_ns: started)
