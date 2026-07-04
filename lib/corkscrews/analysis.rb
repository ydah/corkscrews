# frozen_string_literal: true

require "json"

require_relative "statistics"

module Corkscrews
  class Analysis
    SPEEDUPS = (0..95).step(5).to_a.freeze

    Run = Struct.new(:pid, :run_id, :repeat_index, :duration_ns, :samples, :waits, :progress, :latency, :rounds, :native, :runtime, keyword_init: true)

    class << self
      def load(path)
        new(parse_events(path))
      end

      private

      def parse_events(path)
        File.readlines(path, chomp: true).filter_map do |line|
          next if line.strip.empty?

          JSON.parse(line)
        end
      end
    end

    def initialize(events)
      @events = events
      @runs = build_runs(events)
    end

    attr_reader :events, :runs

    def empty?
      @runs.empty?
    end

    def aggregate
      {
        run_count: @runs.length,
        duration_ns: @runs.sum(&:duration_ns),
        total_samples: @runs.sum { |run| run.samples.values.sum { |value| value[:samples] } },
        progress: aggregate_progress,
        latency: aggregate_latency,
        native: aggregate_native,
        runtime: aggregate_runtime,
        rounds: aggregate_rounds,
        targets: aggregate_targets
      }
    end

    def target_curve(file: nil, line: nil, kind: "line", name: nil)
      target = aggregate_targets.find do |candidate|
        if kind.to_s == "wait"
          candidate[:kind] == "wait" && candidate[:name] == name.to_s
        else
          candidate[:kind] == "line" &&
            File.expand_path(candidate[:file]) == File.expand_path(file) &&
            candidate[:line].to_i == line.to_i
        end
      end

      target&.fetch(:curve)
    end

    private

    def build_runs(events)
      grouped = Hash.new do |hash, key|
        hash[key] = {
          samples: Hash.new(0),
          causal_samples: Hash.new(0),
          waits: Hash.new { |wait_hash, wait_key| wait_hash[wait_key] = { count: 0, duration_ns: 0 } },
          progress: {},
          latency: {},
          rounds: [],
          native: {},
          runtime: {},
          native_samples: []
        }
      end

      events.each do |event|
        key = [event["pid"], event["run_id"], event["repeat_index"]]
        bucket = grouped[key]

        case event["type"]
        when "process"
          bucket[:duration_ns] = event.fetch("duration_ns")
        when "progress"
          bucket[:progress][event.fetch("name")] = {
            count: event.fetch("count"),
            observed_ns: event.fetch("observed_ns")
          }
        when "latency"
          bucket[:latency][event.fetch("name")] = {
            begin_count: event.fetch("begin_count"),
            end_count: event.fetch("end_count"),
            completed_count: event.fetch("completed_count", 0),
            total_duration_ns: event.fetch("total_duration_ns", 0),
            mean_duration_ns: event.fetch("mean_duration_ns", 0),
            little_mean_duration_ns: event.fetch("little_mean_duration_ns", event.fetch("mean_duration_ns", 0)),
            inflight_area_ns: event.fetch("inflight_area_ns", 0)
          }
        when "line"
          target = event.fetch("target")
          key = [target.fetch("file"), target.fetch("line")]
          bucket[:samples][key] += event.fetch("samples")
          bucket[:causal_samples][key] += event.fetch("causal_samples", event.fetch("samples"))
        when "wait"
          target = event.fetch("target")
          wait = bucket[:waits][target.fetch("name")]
          wait[:count] += event.fetch("count")
          wait[:duration_ns] += event.fetch("duration_ns")
        when "round"
          bucket[:rounds] << event
        when "native"
          bucket[:native] = event
        when "native_sample"
          bucket[:native_samples] << event
        when "runtime"
          bucket[:runtime] = event
        end
      end

      grouped.map do |(pid, run_id, repeat_index), bucket|
        Run.new(
          pid: pid,
          run_id: run_id,
          repeat_index: repeat_index,
          duration_ns: bucket[:duration_ns].to_i,
          samples: merge_sample_counts(bucket[:samples], bucket[:causal_samples]),
          waits: bucket[:waits],
          progress: bucket[:progress],
          latency: bucket[:latency],
          rounds: bucket[:rounds],
          native: merge_native(bucket[:native], bucket[:native_samples]),
          runtime: bucket[:runtime]
        )
      end
    end

    def merge_native(native, native_samples)
      return native if native_samples.empty?

      snapshot = native.fetch("snapshot", {}).dup
      snapshot["ring_events"] = native_samples.length
      snapshot["ring_target_hits"] = native_samples.count { |entry| entry["target_hit"] }
      native.merge("snapshot" => snapshot, "samples" => native_samples)
    end

    def merge_sample_counts(samples, causal_samples)
      samples.to_h do |key, count|
        [key, { samples: count, causal_samples: causal_samples.fetch(key, count) }]
      end
    end

    def aggregate_progress
      names = @runs.flat_map { |run| run.progress.keys }.uniq

      names.to_h do |name|
        rates = @runs.filter_map do |run|
          progress = run.progress[name]
          next unless progress

          ns = progress[:observed_ns].positive? ? progress[:observed_ns] : run.duration_ns
          progress[:count].to_f / (ns.to_f / 1_000_000_000)
        end

        [name, {
          mean_rate: Statistics.mean(rates),
          rate_ci: Statistics.bootstrap_mean_ci(rates),
          count: @runs.sum { |run| run.progress.dig(name, :count).to_i }
        }]
      end
    end

    def aggregate_targets
      all_sites = @runs.flat_map { |run| run.samples.keys }.uniq

      # Paper basis: Coz SOSP'15 Section 2 "Producing a causal profile"
      # groups experiments by the optimized line and plots program speedup
      # against virtual speedup.
      # Paper URL: https://arxiv.org/abs/1608.03676
      line_targets = all_sites.map do |file, line|
        shares = @runs.map do |run|
          total = run.samples.values.sum { |value| value[:samples] }
          total.positive? ? capped_share(run.samples.dig([file, line], :samples).to_f / total) : 0.0
        end
        causal_shares = @runs.map do |run|
          total = run.samples.values.sum { |value| value[:samples] }
          total.positive? ? capped_share(run.samples.dig([file, line], :causal_samples).to_f / total) : 0.0
        end
        mean_share = Statistics.mean(shares)
        share_ci = Statistics.bootstrap_mean_ci(shares)
        causal_curve = curve_for(causal_shares)

        {
          kind: "line",
          file: file,
          line: line,
          samples: @runs.sum { |run| run.samples.dig([file, line], :samples).to_i },
          causal_samples: @runs.sum { |run| run.samples.dig([file, line], :causal_samples).to_i },
          sample_share: mean_share,
          sample_share_ci: share_ci,
          causal_share: Statistics.mean(causal_shares),
          curve: causal_curve,
          profile_curve: curve_for(shares),
          round_curve: round_curve_for_target(kind: "line", file: file, line: line),
          curve_source: "causal_share",
          verdict: verdict_for(causal_curve)
        }
      end

      wait_targets = aggregate_wait_targets
      (line_targets + wait_targets).sort_by { |target| -target[:sample_share] }
    end

    def aggregate_wait_targets
      kinds = @runs.flat_map { |run| run.waits.keys }.uniq

      # Paper basis: Ousterhout et al. NSDI'15 Section 2.3.1 measures
      # blocked time from the compute thread's perspective and Section
      # 2.3.2 treats subtracting blocked time as an upper-bound simulation.
      # Paper URL: https://www.usenix.org/system/files/conference/nsdi15/nsdi15-paper-ousterhout.pdf
      kinds.map do |kind|
        shares = @runs.map do |run|
          next 0.0 unless run.duration_ns.positive?

          capped_share(run.waits.dig(kind, :duration_ns).to_f / run.duration_ns)
        end
        curve = curve_for(shares)

        {
          kind: "wait",
          name: kind,
          samples: @runs.sum { |run| run.waits.dig(kind, :count).to_i },
          sample_share: Statistics.mean(shares),
          sample_share_ci: Statistics.bootstrap_mean_ci(shares),
          causal_share: Statistics.mean(shares),
          duration_ns: @runs.sum { |run| run.waits.dig(kind, :duration_ns).to_i },
          curve: curve,
          round_curve: round_curve_for_target(kind: "wait", name: kind),
          curve_source: "causal_share",
          verdict: verdict_for(curve)
        }
      end
    end

    def aggregate_latency
      names = @runs.flat_map { |run| run.latency.keys }.uniq

      # Paper basis: Coz SOSP'15 Section 3.3 "Measuring latency" uses
      # Little's Law, L = lambda W, for paired progress points.
      # Paper URL: https://arxiv.org/abs/1608.03676
      names.to_h do |name|
        means = @runs.filter_map do |run|
          latency = run.latency[name]
          next unless latency

          latency[:mean_duration_ns].to_f / 1_000_000
        end
        little_means = @runs.filter_map do |run|
          latency = run.latency[name]
          next unless latency

          latency[:little_mean_duration_ns].to_f / 1_000_000
        end
        [name, {
          mean_ms: Statistics.mean(means),
          mean_ms_ci: Statistics.bootstrap_mean_ci(means),
          little_mean_ms: Statistics.mean(little_means),
          little_mean_ms_ci: Statistics.bootstrap_mean_ci(little_means),
          completed_count: @runs.sum { |run| run.latency.dig(name, :completed_count).to_i }
        }]
      end
    end

    def aggregate_native
      snapshots = @runs.map { |run| run.native.fetch("snapshot", {}) if run.native }.compact
      keys = snapshots.flat_map(&:keys).uniq
      keys.to_h do |key|
        values = snapshots.map { |snapshot| snapshot[key] }
        [key.to_sym, aggregate_native_value(key, values)]
      end
    end

    def aggregate_native_value(key, values)
      return values.any? if values.any? { |value| value == true || value == false }
      return values.map(&:to_i).max if native_max_key?(key)

      values.sum { |value| value.to_i }
    end

    def native_max_key?(key)
      key.to_s.start_with?("thread_state_") || %w[
        thread_live_count
        thread_max_live_count
        record_ring_size
      ].include?(key.to_s)
    end

    def aggregate_runtime
      {
        fiber_switches: @runs.sum { |run| run.runtime.fetch("fiber_switches", 0).to_i },
        max_fiber_count: @runs.map { |run| run.runtime.fetch("fiber_count", 0).to_i }.max || 0,
        fiber_thread_count: @runs.map { |run| run.runtime.fetch("fiber_thread_count", 0).to_i }.max || 0,
        fiber_scheduler: @runs.any? { |run| run.runtime.fetch("fiber_scheduler", false) },
        max_ractor_count: @runs.map { |run| run.runtime.fetch("ractor_count", 1).to_i }.max || 1
      }
    end

    def aggregate_rounds
      @runs.flat_map(&:rounds)
    end

    def curve_for(shares)
      points = SPEEDUPS.map do |speedup_pct|
        improvements = shares.map { |share| improvement_pct(share, speedup_pct) }
        ci = Statistics.bootstrap_mean_ci(improvements)

        {
          speedup_pct: speedup_pct,
          improvement_pct: Statistics.mean(improvements),
          ci_low: ci[0],
          ci_high: ci[1]
        }
      end

      Statistics.monotonic_regression(points)
    end

    def round_curve_for_target(kind:, file: nil, line: nil, name: nil)
      target_rounds = matching_rounds(kind: kind, file: file, line: line, name: name)
      return nil if target_rounds.empty?

      # Paper basis: Coz SOSP'15 Section 2 requires a 0% baseline per
      # target, then computes program speedup relative to that baseline.
      # Paper URL: https://arxiv.org/abs/1608.03676
      baseline_rates = target_rounds
        .select { |round| round.fetch("baseline", false) || round.fetch("speedup_pct").to_i.zero? }
        .filter_map { |round| round_rate(round) }
      return nil if baseline_rates.empty?

      baseline = Statistics.median(baseline_rates)
      return nil unless baseline.positive?

      observed_by_speedup = target_rounds.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |round, hash|
        speedup_pct = round.fetch("speedup_pct").to_i
        rate = round_rate(round)
        next unless rate

        hash[speedup_pct] << ((rate / baseline) - 1.0) * 100.0
      end
      return nil unless round_curve_covered?(observed_by_speedup)

      points = SPEEDUPS.map do |speedup_pct|
        improvements = observed_by_speedup.fetch(speedup_pct, [])

        if improvements.empty?
          interpolated = interpolated_round_improvement(observed_by_speedup, speedup_pct)
          { speedup_pct: speedup_pct, improvement_pct: interpolated, ci_low: interpolated, ci_high: interpolated }
        else
          ci = Statistics.bootstrap_mean_ci(improvements)
          {
            speedup_pct: speedup_pct,
            improvement_pct: Statistics.mean(improvements),
            ci_low: ci[0],
            ci_high: ci[1]
          }
        end
      end

      Statistics.monotonic_regression(points)
    end

    def round_curve_covered?(observed_by_speedup)
      return false if observed_by_speedup.fetch(0, []).length < 2

      major_speedups = [25, 50, 90]
      observed_nonzero = observed_by_speedup.keys.reject(&:zero?)
      return true if major_speedups.all? { |speedup| observed_by_speedup.key?(speedup) }

      observed_nonzero.length >= 6
    end

    def interpolated_round_improvement(observed_by_speedup, speedup_pct)
      return Statistics.mean(observed_by_speedup.fetch(speedup_pct)) if observed_by_speedup.key?(speedup_pct)

      observed = observed_by_speedup.keys.sort
      lower = observed.select { |candidate| candidate < speedup_pct }.max
      upper = observed.select { |candidate| candidate > speedup_pct }.min
      return 0.0 unless lower || upper
      return Statistics.mean(observed_by_speedup.fetch(upper)) unless lower
      return Statistics.mean(observed_by_speedup.fetch(lower)) unless upper

      lower_value = Statistics.mean(observed_by_speedup.fetch(lower))
      upper_value = Statistics.mean(observed_by_speedup.fetch(upper))
      span = upper - lower
      return lower_value if span.zero?

      lower_value + ((upper_value - lower_value) * ((speedup_pct - lower).to_f / span))
    end

    def matching_rounds(kind:, file: nil, line: nil, name: nil)
      aggregate_rounds.select do |round|
        target = round.fetch("target", {})
        if kind.to_s == "wait"
          target.fetch("kind", nil) == "wait" && target.fetch("name", nil).to_s == name.to_s
        else
          target.fetch("kind", nil) == "line" &&
            File.expand_path(target.fetch("file", "")) == File.expand_path(file) &&
            target.fetch("line", nil).to_i == line.to_i
        end
      end
    end

    def round_rate(round)
      visits = round.fetch("visits", 0).to_f
      duration_ns = round.fetch("virtual_duration_ns", round.fetch("physical_duration_ns", 0)).to_f
      return nil unless visits.positive? && duration_ns.positive?

      visits / (duration_ns / 1_000_000_000.0)
    end

    def improvement_pct(share, speedup_pct)
      # Paper basis: Coz SOSP'15 Section 2 / Figure 3 virtual speedup:
      # reducing a fraction of execution by s predicts 1 / (1 - share*s).
      # Paper URL: https://arxiv.org/abs/1608.03676
      reduced_fraction = share.to_f * (speedup_pct.to_f / 100.0)
      return 0.0 if reduced_fraction <= 0.0
      return Float::INFINITY if reduced_fraction >= 1.0

      ((1.0 / (1.0 - reduced_fraction)) - 1.0) * 100.0
    end

    def capped_share(value)
      [[value.to_f, 0.0].max, 0.95].min
    end

    def verdict_for(curve)
      point = curve.find { |entry| entry[:speedup_pct] == 25 }
      return "insufficient" unless point
      return "bottleneck" if point[:ci_low].positive?
      return "negative" if point[:ci_high].negative?

      "unknown"
    end
  end
end
