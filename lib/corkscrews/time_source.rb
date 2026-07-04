# frozen_string_literal: true

module Corkscrews
  module TimeSource
    module_function

    def monotonic_ns
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    end
  end
end
