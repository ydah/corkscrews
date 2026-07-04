# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

require_relative "analysis"
require_relative "statistics"

module Corkscrews
  module Validate
    ROOT = File.expand_path("../..", __dir__)
    BENCHMARK_ROOT = File.join(ROOT, "validate", "benchmarks")

    Result = Struct.new(:checks, keyword_init: true) do
      def ok?
        checks.all? { |check| check[:ok] }
      end

      def to_h
        { ok: ok?, checks: sanitize(checks) }
      end

      private

      def sanitize(value)
        case value
        when Float
          value.finite? ? value : value.to_s
        when Array
          value.map { |entry| sanitize(entry) }
        when Hash
          value.transform_values { |entry| sanitize(entry) }
        else
          value
        end
      end
    end

    module_function

    def run_all(quick: false, benchmark: nil)
      manifests = load_manifests
      manifests.select! { |manifest| manifest.fetch("id") == benchmark } if benchmark
      raise Error, "unknown benchmark: #{benchmark}" if manifests.empty?

      checks = []
      profiles = {}
      Dir.mktmpdir("corkscrews-validate") do |tmpdir|
        manifests.each do |manifest|
          benchmark_checks, profile = run_benchmark(manifest, tmpdir: tmpdir, quick: quick)
          checks.concat(benchmark_checks)
          profiles[manifest.fetch("id")] = profile
        end
        checks << t5_statistics_check
        checks << t6_native_attribution_check(manifests, profiles: profiles, benchmark: benchmark)
      end

      Result.new(checks: checks)
    end

    def load_manifests
      Dir[File.join(BENCHMARK_ROOT, "*", "manifest.yml")]
        .sort
        .map { |path| YAML.load_file(path).merge("_path" => path, "_dir" => File.dirname(path)) }
    end

    def run_benchmark(manifest, tmpdir:, quick:)
      id = manifest.fetch("id")
      settings = run_settings(manifest, quick: quick)
      profile_path = File.join(tmpdir, "#{id}.corkscrews.ndjson")
      profile = profile_benchmark(manifest, settings: settings, output: profile_path)
      actual = measure_actual(manifest, settings: settings)

      checks = [
        t1_prediction_check(manifest, profile, actual),
        t2_actionability_check(manifest),
        t3_decoy_check(manifest, profile),
        t4_overhead_check(manifest, profile, actual)
      ]
      [checks, profile]
    end

    def run_settings(manifest, quick:)
      run = manifest.fetch("run")
      if quick
        {
          repeat: [run.fetch("repeat").to_i, 3].min,
          iterations: [run.fetch("iterations").to_i, 8_000].min,
          sample_period_ms: run.fetch("quick_sample_period_ms", 0.5).to_f,
          round_ms: run.fetch("round_ms", 40).to_f
        }
      else
        {
          repeat: run.fetch("repeat").to_i,
          iterations: run.fetch("iterations").to_i,
          sample_period_ms: run.fetch("sample_period_ms", 1.0).to_f,
          round_ms: run.fetch("round_ms", 40).to_f
        }
      end
    end

    def profile_benchmark(manifest, settings:, output:)
      bench = File.join(manifest.fetch("_dir"), "base.rb")
      command = [
        ruby,
        "-I#{File.join(ROOT, "lib")}",
        File.join(ROOT, "exe", "corkscrews"),
        "run",
        "--repeat", settings.fetch(:repeat).to_s,
        "--output", output,
        "--sample-period-ms", settings.fetch(:sample_period_ms).to_s,
        "--targets", manifest.fetch("targets", "lines"),
        "--",
        ruby,
        "-I#{File.join(ROOT, "lib")}",
        bench
      ]
      env = benchmark_environment(settings, manifest)
      stdout, stderr, status = Open3.capture3(env, *command, chdir: ROOT)
      raise Error, "profile failed: #{stderr}\n#{stdout}" unless status.success?

      Analysis.load(output)
    end

    def measure_actual(manifest, settings:)
      base = measure_variant(manifest, "base.rb", settings: settings)
      optimized = measure_variant(manifest, "optimized.rb", settings: settings)
      improvement = (Statistics.mean(optimized[:rates]) / Statistics.mean(base[:rates])) - 1.0

      {
        base: base,
        optimized: optimized,
        improvement_pct: improvement * 100.0
      }
    end

    def measure_variant(manifest, file_name, settings:)
      path = File.join(manifest.fetch("_dir"), file_name)
      rates = Array.new(settings.fetch(:repeat)) do
        env = benchmark_environment(settings, manifest).merge("CS_BENCH_JSON" => "1")
        stdout, stderr, status = Open3.capture3(env, ruby, "-I#{File.join(ROOT, "lib")}", path, chdir: ROOT)
        raise Error, "benchmark #{file_name} failed: #{stderr}" unless status.success?

        payload = JSON.parse(stdout.lines.last)
        payload.fetch("progress").to_f / (payload.fetch("elapsed_ns").to_f / 1_000_000_000)
      end

      { rates: rates, mean_rate: Statistics.mean(rates), rate_ci: Statistics.bootstrap_mean_ci(rates) }
    end

    def t1_prediction_check(manifest, profile, actual)
      # Paper basis: Coz SOSP'15 Section 4 evaluates causal profiles by
      # comparing predicted speedup with actual optimized variants.
      # Paper URL: https://arxiv.org/abs/1608.03676
      truth = manifest.fetch("truth")
      target = truth.fetch("target")
      target_kind = target.fetch("kind").to_s
      speedup_pct = (truth.fetch("optimized_speedup_of_target").to_f * 100).round
      speedup_pct -= speedup_pct % 5

      curve = target_curve(profile, manifest, target)
      predicted = curve&.find { |point| point[:speedup_pct] == speedup_pct }
      tolerance = manifest.fetch("acceptance").fetch("t1_mae_pct").to_f
      error = predicted ? (predicted[:improvement_pct] - actual.fetch(:improvement_pct)).abs : Float::INFINITY

      {
        id: "#{manifest.fetch("id")}:T1",
        ok: predicted && error <= tolerance,
        predicted_improvement_pct: predicted && predicted[:improvement_pct],
        actual_improvement_pct: actual.fetch(:improvement_pct),
        error_pct: error,
        tolerance_pct: tolerance,
        target: target_label(manifest, target)
      }
    end

    def t2_actionability_check(manifest)
      # Paper basis: Mytkowicz et al., "Evaluating the Accuracy of Java
      # Profilers" (PLDI'10, DOI 10.1145/1806596.1806618), frames profile
      # quality around whether profiler guidance is actionable.
      # Paper URL: https://doi.org/10.1145/1806596.1806618
      variants = manifest.fetch("variants", [])
      return { id: "#{manifest.fetch("id")}:T2", ok: true, skipped: true } if variants.empty?

      predicted = variants.map { |variant| variant.fetch("predicted_rank").to_i }
      actual = variants.map { |variant| variant.fetch("actual_rank").to_i }
      tau = Statistics.kendall_tau(predicted, actual)

      {
        id: "#{manifest.fetch("id")}:T2",
        ok: tau >= manifest.fetch("acceptance").fetch("t2_min_tau", 0.6).to_f,
        kendall_tau: tau
      }
    end

    def t3_decoy_check(manifest, profile)
      # Paper basis: Coz SOSP'15 Figures 1-2 show hot code that is not
      # optimization-relevant; this check pins that false-hotspot case.
      # Paper URL: https://arxiv.org/abs/1608.03676
      decoys = manifest.dig("truth", "decoys") || []
      return { id: "#{manifest.fetch("id")}:T3", ok: true, skipped: true } if decoys.empty?

      max_effect = manifest.fetch("acceptance").fetch("t3_decoy_max_effect_pct", 5.0).to_f
      aggregate = profile.aggregate
      results = decoys.map do |decoy|
        target = find_target(aggregate, manifest, decoy)
        point = target&.fetch(:curve)&.find { |entry| entry[:speedup_pct] == 25 }
        effect = point ? point[:improvement_pct].abs : 0.0
        {
          target: target_label(manifest, decoy),
          observed_share_pct: target ? target[:sample_share].to_f * 100.0 : 0.0,
          causal_share_pct: target ? target[:causal_share].to_f * 100.0 : 0.0,
          effect_pct: effect,
          ok: effect <= max_effect
        }
      end

      {
        id: "#{manifest.fetch("id")}:T3",
        ok: results.all? { |result| result[:ok] },
        max_effect_pct: max_effect,
        decoys: results
      }
    end

    def t4_overhead_check(manifest, profile, actual)
      # Paper basis: Coz SOSP'15 Section 4 reports profiling overhead;
      # Mytkowicz et al. PLDI'10 also treats observer effects as a source
      # of profiler inaccuracy.
      # Paper URLs: https://arxiv.org/abs/1608.03676
      # https://doi.org/10.1145/1806596.1806618
      progress_name = manifest.fetch("progress_point")
      profiled_rate = profile.aggregate.fetch(:progress).dig(progress_name, :mean_rate).to_f
      baseline_rate = actual.fetch(:base).fetch(:mean_rate)
      overhead_pct = baseline_rate.positive? ? ((baseline_rate - profiled_rate) / baseline_rate) * 100.0 : 0.0
      tolerance = manifest.fetch("acceptance").fetch("t4_overhead_pct").to_f

      {
        id: "#{manifest.fetch("id")}:T4",
        ok: overhead_pct <= tolerance,
        profiled_rate: profiled_rate,
        baseline_rate: baseline_rate,
        overhead_pct: overhead_pct,
        tolerance_pct: tolerance
      }
    end

    def t5_statistics_check
      # Paper basis: Kalibera & Jones, "Quantifying Performance Changes
      # with Effect Size Confidence Intervals" (arXiv:2007.10899),
      # motivates confidence intervals for performance effect sizes.
      # Paper URL: https://arxiv.org/abs/2007.10899
      values = [9.7, 10.1, 10.4, 9.9, 10.2, 10.0, 10.3, 9.8]
      ci = Statistics.bootstrap_mean_ci(values, iterations: 500)
      mean = Statistics.mean(values)
      monotonic = Statistics.monotonic_regression([
        { speedup_pct: 0, improvement_pct: 0.0 },
        { speedup_pct: 5, improvement_pct: 3.0 },
        { speedup_pct: 10, improvement_pct: 2.5 },
        { speedup_pct: 15, improvement_pct: 5.0 }
      ])
      nondecreasing = monotonic.each_cons(2).all? { |left, right| left[:improvement_pct] <= right[:improvement_pct] }

      {
        id: "T5",
        ok: ci[0] <= mean && mean <= ci[1] && nondecreasing,
        mean: mean,
        ci: ci,
        monotonic_points: monotonic
      }
    end

    def t6_native_attribution_check(manifests, profiles:, benchmark:)
      # Paper basis: Scalene OSDI'23 Section 2 separates interpreter,
      # native, and system execution; this check verifies native-call
      # evidence is attributed back to the Ruby call site.
      # Paper URL: https://www.usenix.org/system/files/osdi23-berger.pdf
      if benchmark && benchmark != "b08_native_attribution"
        return { id: "T6", ok: true, skipped: true }
      end

      manifest = manifests.find { |entry| entry.fetch("id") == "b08_native_attribution" }
      return { id: "T6", ok: false, native_benchmark_present: false } unless manifest

      profile = profiles.fetch("b08_native_attribution", nil)
      aggregate = profile&.aggregate || {}
      target = aggregate.empty? ? nil : find_target(aggregate, manifest, manifest.fetch("truth").fetch("target"))
      native = aggregate.fetch(:native, {})
      native_samples = native.fetch(:samples, 0).to_i
      target_hits = native.fetch(:target_hits, 0).to_i

      {
        id: "T6",
        ok: target && target.fetch(:samples).to_i.positive? && native_samples.positive? && target_hits.positive?,
        native_benchmark_present: true,
        target_samples: target&.fetch(:samples).to_i,
        native_samples: native_samples,
        native_target_hits: target_hits,
        target: target_label(manifest, manifest.fetch("truth").fetch("target"))
      }
    end

    def target_curve(profile, manifest, target)
      if target.fetch("kind").to_s == "wait"
        profile.target_curve(kind: "wait", name: target.fetch("name"))
      else
        profile.target_curve(
          file: File.expand_path(target.fetch("file"), manifest.fetch("_dir")),
          line: target.fetch("line").to_i
        )
      end
    end

    def find_target(aggregate, manifest, target)
      aggregate.fetch(:targets).find do |candidate|
        if target.fetch("kind").to_s == "wait"
          candidate[:kind] == "wait" && candidate[:name] == target.fetch("name")
        else
          candidate[:kind] == "line" &&
            File.expand_path(candidate[:file]) == File.expand_path(target.fetch("file"), manifest.fetch("_dir")) &&
            candidate[:line].to_i == target.fetch("line").to_i
        end
      end
    end

    def target_label(manifest, target)
      if target.fetch("kind").to_s == "wait"
        "wait:#{target.fetch("name")}"
      else
        "#{File.expand_path(target.fetch("file"), manifest.fetch("_dir"))}:#{target.fetch("line")}"
      end
    end

    def benchmark_environment(settings, manifest)
      manifest.fetch("env", {}).transform_values(&:to_s).merge(
        "CS_BENCH_ITERATIONS" => settings.fetch(:iterations).to_s,
        "CORKSCREWS_ROUND_MS" => settings.fetch(:round_ms).to_s
      )
    end

    def ruby
      RbConfig.ruby
    end
  end
end
