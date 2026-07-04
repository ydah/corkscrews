# frozen_string_literal: true

require "securerandom"

require_relative "analysis"

module Corkscrews
  class Controller
    SPEEDUPS = Analysis::SPEEDUPS.freeze
    DEFAULT_RANDOM = Random.new(12_345)

    Round = Struct.new(
      :id,
      :target,
      :speedup_pct,
      :baseline,
      :visits,
      :physical_duration_ns,
      :virtual_duration_ns,
      keyword_init: true
    )

    def initialize(targets:, random: DEFAULT_RANDOM)
      @targets = targets
      @random = random
      @round_index = 0
    end

    def next_round(progress_visits:, duration_ns:, targets: nil, history: [])
      active_targets = targets || @targets
      target = pick_target(active_targets, history)
      speedup_pct = pick_speedup(target, history)
      share = target_share(target)
      reduced = share * (speedup_pct.to_f / 100.0)

      Round.new(
        id: next_round_id,
        target: target,
        speedup_pct: speedup_pct,
        baseline: speedup_pct.zero?,
        visits: progress_visits,
        physical_duration_ns: duration_ns,
        virtual_duration_ns: (duration_ns * (1.0 - reduced)).round
      )
    end

    def self.plan_for(analysis, rounds: 32, random: DEFAULT_RANDOM)
      aggregate = analysis.aggregate
      controller = new(targets: aggregate[:targets].first(32), random: random)
      progress_count = aggregate[:progress].values.sum { |entry| entry[:count].to_i }
      duration_ns = aggregate[:duration_ns]

      Array.new(rounds) do
        controller.next_round(progress_visits: progress_count, duration_ns: duration_ns)
      end
    end

    private

    # Paper basis: Coz SOSP'15 Section 2 "Experiment initialization"
    # and Section 3.2 select the speedup target/amount during execution;
    # Stabilizer ASPLOS'13 Section 2 motivates randomized exploration to
    # avoid systematic measurement bias.
    # Paper URLs: https://arxiv.org/abs/1608.03676
    # https://people.cs.umass.edu/~emery/pubs/stabilizer-asplos13.pdf
    def pick_target(targets, history)
      return { kind: "none", sample_share: 0.0, causal_share: 0.0 } if targets.empty?

      total = targets.sum { |target| target_weight(target, history) }
      cursor = @random.rand * total
      targets.each do |target|
        cursor -= target_weight(target, history)
        return target if cursor <= 0.0
      end
      targets.last
    end

    # Paper basis: Coz SOSP'15 Section 3.2 gives 0% virtual speedup
    # 50% probability because every target needs a local baseline.
    # Paper URL: https://arxiv.org/abs/1608.03676
    def pick_speedup(target, history)
      target_history = history_for_target(target, history)
      baseline_count = target_history.count { |round| round.fetch(:speedup_pct, round["speedup_pct"]).to_i.zero? }
      nonbaseline_count = target_history.length - baseline_count
      return 0 if baseline_count <= nonbaseline_count / 2

      uncovered = priority_speedups.reject do |speedup|
        target_history.any? { |round| round.fetch(:speedup_pct, round["speedup_pct"]).to_i == speedup }
      end
      return uncovered.first if uncovered.any?

      SPEEDUPS.reject(&:zero?).fetch(@random.rand(SPEEDUPS.length - 1))
    end

    def next_round_id
      @round_index += 1
      "round-#{@round_index}-#{SecureRandom.hex(3)}"
    end

    def target_weight(target, history)
      count = history_for_target(target, history).length
      share = [target_share(target), 0.0001].max
      exploration = 1.0 / Math.sqrt(count + 1)
      coverage = missing_priority_speedups(target, history) * 0.05
      share * exploration + coverage
    end

    def target_share(target)
      target.fetch(:causal_share, target.fetch(:sample_share, target.fetch(:share, 0.0))).to_f
    end

    def missing_priority_speedups(target, history)
      seen = history_for_target(target, history).map { |round| round.fetch(:speedup_pct, round["speedup_pct"]).to_i }
      priority_speedups.count { |speedup| !seen.include?(speedup) }
    end

    def priority_speedups
      [0, 25, 50, 90]
    end

    def history_for_target(target, history)
      key = target_key(target)
      history.select { |round| target_key(round.fetch(:target, round["target"])) == key }
    end

    def target_key(target)
      return ["none"] unless target

      kind = target.fetch(:kind, target["kind"]).to_s
      if kind == "wait"
        [kind, target.fetch(:name, target["name"]).to_s]
      else
        [kind, File.expand_path(target.fetch(:file, target["file"]).to_s), target.fetch(:line, target["line"]).to_i]
      end
    end
  end
end
