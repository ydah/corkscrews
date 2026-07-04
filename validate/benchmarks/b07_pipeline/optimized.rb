# frozen_string_literal: true

require_relative "../support"

iterations = CorkscrewsBench.iterations(160)
started = CorkscrewsBench.monotonic_ns
parse_q = Thread::SizedQueue.new(8)
write_q = Thread::SizedQueue.new(8)

parser = Thread.new do
  iterations.times do |i|
    CorkscrewsBench.busy(2_000)
    parse_q << i
  end
end

transformer = Thread.new do
  iterations.times do
    item = parse_q.pop
    CorkscrewsBench.busy(4_000)
    write_q << item
  end
end

writer = Thread.new do
  iterations.times do
    write_q.pop
    CorkscrewsBench.busy(2_000)
    Corkscrews.progress(:work_done)
  end
end

[parser, transformer, writer].each(&:join)
CorkscrewsBench.finish(progress: iterations, started_ns: started)
