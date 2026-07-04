# frozen_string_literal: true

require_relative "../support"

def gvl_work
  20_000.times.sum { |i| Integer.sqrt((i * i) + 7) }
end

iterations = CorkscrewsBench.iterations(200)
started = CorkscrewsBench.monotonic_ns
done = Queue.new

4.times do
  Thread.new do
    (iterations / 4).times do
      gvl_work
      Corkscrews.progress(:work_done)
    end
    done << true
  end
end

4.times { done.pop }
CorkscrewsBench.finish(progress: iterations - (iterations % 4), started_ns: started)
