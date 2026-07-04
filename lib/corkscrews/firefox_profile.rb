# frozen_string_literal: true

module Corkscrews
  class FirefoxProfile
    MAX_SYNTHETIC_SAMPLES = 10_000

    class << self
      def build(aggregate)
        new(aggregate).build
      end
    end

    def initialize(aggregate)
      @aggregate = aggregate
      @strings = []
      @string_indexes = {}
    end

    def build
      thread = build_thread

      {
        "meta" => meta,
        "libs" => [],
        "pages" => [],
        "profileGatheringLog" => [],
        "threads" => [thread]
      }
    end

    private

    def meta
      {
        "version" => 34,
        "product" => "corkscrews",
        "interval" => sample_interval_ms,
        "processType" => 0,
        "platform" => RUBY_PLATFORM,
        "misc" => "Ruby #{RUBY_VERSION}"
      }
    end

    def build_thread
      targets = @aggregate.fetch(:targets, [])
      funcs = build_funcs(targets)
      frames = build_frames(targets)
      stacks = build_stacks(targets)
      samples = build_samples(targets)
      markers = build_markers(targets)

      {
        "name" => "corkscrews aggregate",
        "processType" => "default",
        "processName" => "corkscrews",
        "isMainThread" => true,
        "pid" => 0,
        "tid" => 0,
        "registerTime" => 0,
        "unregisterTime" => duration_ms,
        "stringArray" => @strings,
        "stringTable" => @strings,
        "resourceTable" => empty_resource_table,
        "funcTable" => funcs,
        "frameTable" => frames,
        "stackTable" => stacks,
        "samples" => samples,
        "markers" => markers,
        "pausedRanges" => []
      }
    end

    def build_funcs(targets)
      {
        "schema" => {
          "name" => 0,
          "isJS" => 1,
          "resource" => 2,
          "relevantForJS" => 3
        },
        "data" => targets.map { |target| [string_index(target_label(target)), false, -1, false] }
      }
    end

    def build_frames(targets)
      {
        "schema" => {
          "address" => 0,
          "category" => 1,
          "subcategory" => 2,
          "func" => 3,
          "innerWindowID" => 4,
          "implementation" => 5,
          "line" => 6,
          "column" => 7
        },
        "data" => targets.each_with_index.map do |target, index|
          [-1, 0, 0, index, 0, nil, frame_line(target), nil]
        end
      }
    end

    def build_stacks(targets)
      {
        "schema" => {
          "prefix" => 0,
          "frame" => 1,
          "category" => 2,
          "subcategory" => 3
        },
        "data" => targets.each_index.map { |index| [nil, index, 0, 0] }
      }
    end

    def build_samples(targets)
      rows = synthetic_sample_rows(targets)

      {
        "schema" => {
          "stack" => 0,
          "time" => 1,
          "responsiveness" => 2
        },
        "data" => rows
      }
    end

    def build_markers(targets)
      {
        "schema" => {
          "name" => 0,
          "startTime" => 1,
          "endTime" => 2,
          "phase" => 3,
          "category" => 4,
          "data" => 5
        },
        "data" => target_markers(targets) + round_markers
      }
    end

    def target_markers(targets)
      targets.map do |target|
        [
          string_index("#{target[:verdict]}: #{target_label(target)}"),
          0,
          duration_ms,
          1,
          0,
          marker_payload(target)
        ]
      end
    end

    def round_markers
      cursor_ms = 0.0
      @aggregate.fetch(:rounds, []).map do |round|
        duration = round_duration_ms(round)
        start_time = cursor_ms
        cursor_ms += duration

        [
          string_index("round #{round_value(round, :speedup_pct)}% #{target_label(round_target(round))}"),
          rounded_time(start_time),
          rounded_time(cursor_ms),
          1,
          0,
          round_marker_payload(round)
        ]
      end
    end

    def synthetic_sample_rows(targets)
      sample_units = sample_units_for(targets)
      return [] if sample_units.empty?

      total_rows = sample_units.sum
      spacing_ms = total_rows.positive? ? duration_ms / total_rows : sample_interval_ms
      time_ms = 0.0

      sample_units.each_with_index.flat_map do |count, stack_index|
        Array.new(count) do
          row = [stack_index, rounded_time(time_ms), 0]
          time_ms += spacing_ms
          row
        end
      end
    end

    def sample_units_for(targets)
      counts = targets.map { |target| target[:samples].to_i }
      total = counts.sum
      return [] unless total.positive?

      if total <= MAX_SYNTHETIC_SAMPLES
        counts
      else
        counts.map do |count|
          count.positive? ? [((count.to_f / total) * MAX_SYNTHETIC_SAMPLES).round, 1].max : 0
        end
      end
    end

    def marker_payload(target)
      {
        "type" => "CorkscrewsTarget",
        "target" => target_label(target),
        "sampleShare" => target[:sample_share].to_f,
        "causalShare" => target[:causal_share].to_f,
        "samples" => target[:samples].to_i,
        "verdict" => target[:verdict].to_s
      }
    end

    def round_marker_payload(round)
      {
        "type" => "CorkscrewsRound",
        "target" => target_label(round_target(round)),
        "speedupPct" => round_value(round, :speedup_pct).to_i,
        "baseline" => !!round_value(round, :baseline),
        "visits" => round_value(round, :visits).to_i,
        "physicalDurationMs" => round_value(round, :physical_duration_ns).to_f / 1_000_000.0,
        "virtualDurationMs" => round_value(round, :virtual_duration_ns).to_f / 1_000_000.0
      }
    end

    def round_duration_ms(round)
      duration = round_value(round, :physical_duration_ns).to_f / 1_000_000.0
      duration.positive? ? duration : sample_interval_ms
    end

    def round_target(round)
      round_value(round, :target) || { kind: "none" }
    end

    def round_value(round, key)
      round[key] || round[key.to_s]
    end

    def empty_resource_table
      {
        "schema" => {
          "type" => 0,
          "name" => 1,
          "host" => 2
        },
        "data" => []
      }
    end

    def target_label(target)
      kind = target[:kind] || target["kind"]
      if kind == "wait"
        "wait:#{target[:name] || target["name"]}"
      elsif kind == "none"
        "none"
      else
        "#{target[:file] || target["file"]}:#{target[:line] || target["line"]}"
      end
    end

    def frame_line(target)
      return nil if (target[:kind] || target["kind"]) == "wait"

      (target[:line] || target["line"]).to_i
    end

    def sample_interval_ms
      [duration_ms / [@aggregate.fetch(:total_samples, 0).to_i, 1].max, 0.001].max
    end

    def duration_ms
      duration = @aggregate.fetch(:duration_ns, 0).to_f / 1_000_000.0
      duration.positive? ? duration : 1.0
    end

    def rounded_time(value)
      value.round(6)
    end

    def string_index(value)
      key = value.to_s
      @string_indexes.fetch(key) do
        @string_indexes[key] = @strings.length
        @strings << key
        @string_indexes[key]
      end
    end
  end
end
