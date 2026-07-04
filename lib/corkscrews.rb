# frozen_string_literal: true

require_relative "corkscrews/version"
require_relative "corkscrews/recorder"

module Corkscrews
  class Error < StandardError; end

  class << self
    def progress(name = :default)
      Recorder.current&.progress(name)
      nil
    end

    def latency_begin(name = :default)
      Recorder.current&.latency_begin(name)
      nil
    end

    def latency_end(name = :default)
      Recorder.current&.latency_end(name)
      nil
    end

    def record_wait(kind, duration_ns)
      Recorder.current&.record_wait(kind, duration_ns)
      nil
    end

    def start!(output:, run_id: nil, repeat_index: nil, sample_period_ms: nil)
      Recorder.start!(
        output: output,
        run_id: run_id,
        repeat_index: repeat_index,
        sample_period_ms: sample_period_ms
      )
    end

    def stop!
      Recorder.stop!
    end
  end
end
