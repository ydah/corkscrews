# frozen_string_literal: true

module Corkscrews
  module Statistics
    module_function

    def mean(values)
      return 0.0 if values.empty?

      values.sum.to_f / values.length
    end

    def percentile(values, pct)
      return 0.0 if values.empty?

      sorted = values.sort
      index = (pct * (sorted.length - 1)).round
      sorted.fetch(index)
    end

    def percentile_ci(values, lower: 0.025, upper: 0.975)
      [percentile(values, lower), percentile(values, upper)]
    end

    def median(values)
      return 0.0 if values.empty?

      sorted = values.sort
      middle = sorted.length / 2
      return sorted.fetch(middle).to_f if sorted.length.odd?

      (sorted.fetch(middle - 1) + sorted.fetch(middle)).to_f / 2.0
    end

    def bootstrap_mean_ci(values, iterations: 1_000, random: Random.new(12_345))
      return [0.0, 0.0] if values.empty?
      return [values.first.to_f, values.first.to_f] if values.length == 1

      # Paper basis: Kalibera & Jones, "Quantifying Performance Changes
      # with Effect Size Confidence Intervals" (arXiv:2007.10899),
      # motivates reporting uncertainty for performance effect sizes.
      # Paper URL: https://arxiv.org/abs/2007.10899
      means = Array.new(iterations) do
        sample = Array.new(values.length) { values.fetch(random.rand(values.length)) }
        mean(sample)
      end
      percentile_ci(means)
    end

    def monotonic_regression(points)
      ordered = points.sort_by { |point| point[:speedup_pct] }
      blocks = []

      # Paper basis: Coz SOSP'15 Section 2 plots increasing virtual
      # speedup on the x-axis; this pool-adjacent-violators pass enforces
      # the physical monotonicity expected from that curve.
      # Paper URL: https://arxiv.org/abs/1608.03676
      ordered.each do |point|
        blocks << {
          start: point[:speedup_pct],
          finish: point[:speedup_pct],
          weight: 1.0,
          value: point[:improvement_pct].to_f
        }

        while blocks.length >= 2 && blocks[-2][:value] > blocks[-1][:value]
          right = blocks.pop
          left = blocks.pop
          weight = left[:weight] + right[:weight]
          blocks << {
            start: left[:start],
            finish: right[:finish],
            weight: weight,
            value: ((left[:value] * left[:weight]) + (right[:value] * right[:weight])) / weight
          }
        end
      end

      blocks.flat_map do |block|
        ordered
          .select { |point| point[:speedup_pct] >= block[:start] && point[:speedup_pct] <= block[:finish] }
          .map { |point| point.merge(improvement_pct: block[:value]) }
      end
    end

    def kendall_tau(left, right)
      return 0.0 unless left.length == right.length
      return 1.0 if left.length < 2

      concordant = 0
      discordant = 0
      (0...(left.length - 1)).each do |i|
        ((i + 1)...left.length).each do |j|
          left_delta = left[i] <=> left[j]
          right_delta = right[i] <=> right[j]
          next if left_delta.zero? || right_delta.zero?

          if left_delta == right_delta
            concordant += 1
          else
            discordant += 1
          end
        end
      end

      total = concordant + discordant
      return 0.0 if total.zero?

      (concordant - discordant).to_f / total
    end
  end
end
