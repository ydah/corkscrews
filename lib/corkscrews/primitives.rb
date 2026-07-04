# frozen_string_literal: true

require_relative "native"
require_relative "time_source"

module Corkscrews
  module Primitives
    # Paper basis: Ousterhout et al. NSDI'15 Section 2.3.1 instruments
    # time spent blocked from the compute thread's perspective; these
    # prepends adapt that blocked-time accounting to Ruby waits.
    # Paper URL: https://www.usenix.org/system/files/conference/nsdi15/nsdi15-paper-ousterhout.pdf
    module MutexStamp
      def unlock
        Corkscrews::Native.stamp_write(self)
        super
      end

      def lock
        started_ns = Corkscrews::TimeSource.monotonic_ns
        result = super
        Corkscrews.record_wait(:lock_wait, Corkscrews::TimeSource.monotonic_ns - started_ns)
        Corkscrews::Native.stamp_inherit(self)
        result
      end

      def synchronize(&block)
        lock
        begin
          block.call
        ensure
          unlock
        end
      end
    end

    module QueueStamp
      def <<(...)
        push(...)
      end

      def push(...)
        Corkscrews::Native.stamp_write(self)
        started_ns = Corkscrews::TimeSource.monotonic_ns
        result = super
        Corkscrews.record_wait(:queue_wait, Corkscrews::TimeSource.monotonic_ns - started_ns)
        Corkscrews::Native.stamp_inherit(self)
        result
      end

      def pop(...)
        Corkscrews::Native.stamp_write(self)
        started_ns = Corkscrews::TimeSource.monotonic_ns
        result = super
        Corkscrews.record_wait(:queue_wait, Corkscrews::TimeSource.monotonic_ns - started_ns)
        Corkscrews::Native.stamp_inherit(self)
        result
      end

      def deq(...)
        pop(...)
      end
    end

    module CondVarStamp
      def signal
        Corkscrews::Native.stamp_write(self)
        super
      end

      def broadcast
        Corkscrews::Native.stamp_write(self)
        super
      end

      def wait(mutex, timeout = nil)
        started_ns = Corkscrews::TimeSource.monotonic_ns
        result = super
        Corkscrews.record_wait(:condition_wait, Corkscrews::TimeSource.monotonic_ns - started_ns)
        Corkscrews::Native.stamp_inherit(self)
        result
      end
    end

    module KernelWait
      def sleep(...)
        started_ns = Corkscrews::TimeSource.monotonic_ns
        result = super
        Corkscrews.record_wait(:sleep_wait, Corkscrews::TimeSource.monotonic_ns - started_ns)
        result
      end
    end

    module IOWait
      def read(...)
        measure_io_wait { super }
      end

      def readpartial(...)
        measure_io_wait { super }
      end

      def write(...)
        measure_io_wait { super }
      end

      private

      def measure_io_wait
        started_ns = Corkscrews::TimeSource.monotonic_ns
        result = yield
        Corkscrews.record_wait(:io_wait, Corkscrews::TimeSource.monotonic_ns - started_ns)
        result
      end
    end

    def self.install!
      Mutex.prepend MutexStamp unless Mutex.ancestors.include?(MutexStamp)
      Thread::Queue.prepend QueueStamp unless Thread::Queue.ancestors.include?(QueueStamp)
      Thread::SizedQueue.prepend QueueStamp unless Thread::SizedQueue.ancestors.include?(QueueStamp)
      Queue.prepend QueueStamp if defined?(Queue) && !Queue.ancestors.include?(QueueStamp)
      SizedQueue.prepend QueueStamp if defined?(SizedQueue) && !SizedQueue.ancestors.include?(QueueStamp)
      Thread::ConditionVariable.prepend CondVarStamp unless Thread::ConditionVariable.ancestors.include?(CondVarStamp)
      Kernel.prepend KernelWait unless Kernel.ancestors.include?(KernelWait)
      IO.prepend IOWait unless IO.ancestors.include?(IOWait)
    end
  end
end
