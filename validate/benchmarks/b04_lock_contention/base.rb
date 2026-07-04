# frozen_string_literal: true

require_relative "../support"

def critical_work
  CorkscrewsBench.busy(1_200)
end

def outside_work
  CorkscrewsBench.busy(600)
end

iterations = CorkscrewsBench.iterations(180)
started = CorkscrewsBench.monotonic_ns
mutex = Mutex.new
done = Queue.new

4.times do
  Thread.new do
    (iterations / 4).times do
      mutex.synchronize { critical_work }
      outside_work
      Corkscrews.progress(:work_done)
    end
    done << true
  end
end

4.times { done.pop }
CorkscrewsBench.finish(progress: iterations - (iterations % 4), started_ns: started)
