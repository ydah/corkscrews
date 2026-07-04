# frozen_string_literal: true

require "cgi"
require "json"

require_relative "analysis"
require_relative "firefox_profile"

module Corkscrews
  class Report
    def initialize(path)
      @path = path
      @analysis = Analysis.load(path)
    end

    def to_text(limit: 10)
      aggregate = @analysis.aggregate
      lines = []
      lines << "corkscrews report: #{@path}"
      lines << "runs: #{aggregate[:run_count]}  samples: #{aggregate[:total_samples]}  duration: #{format_seconds(aggregate[:duration_ns])}"
      unless aggregate[:native].empty?
        lines << "native: samples=#{aggregate[:native][:samples].to_i} target_hits=#{aggregate[:native][:target_hits].to_i} ring_events=#{aggregate[:native][:ring_events].to_i} monitor_ticks=#{aggregate[:native][:monitor_ticks].to_i} monitor_signals=#{aggregate[:native][:monitor_signals].to_i} monitor_signal_failures=#{aggregate[:native][:monitor_signal_failures].to_i} live_threads=#{aggregate[:native][:thread_live_count].to_i} max_live_threads=#{aggregate[:native][:thread_max_live_count].to_i} debt_settled_ns=#{aggregate[:native][:debt_settled_ns].to_i} gc_pause_ns=#{aggregate[:native][:gc_pause_ns].to_i}"
      end
      lines << "runtime: fiber_switches=#{aggregate[:runtime][:fiber_switches]} max_fibers=#{aggregate[:runtime][:max_fiber_count]} fiber_threads=#{aggregate[:runtime][:fiber_thread_count]} fiber_scheduler=#{aggregate[:runtime][:fiber_scheduler]} max_ractors=#{aggregate[:runtime][:max_ractor_count]}"
      lines << ""

      if aggregate[:progress].empty?
        lines << "progress: none"
      else
        lines << "progress:"
        aggregate[:progress].each do |name, stats|
          ci = stats[:rate_ci]
          lines << format(
            "  %-16s rate=%10.2f/s  ci=[%10.2f,%10.2f]  count=%d",
            name,
            stats[:mean_rate],
            ci[0],
            ci[1],
            stats[:count]
          )
        end
      end

      unless aggregate[:latency].empty?
        lines << ""
        lines << "latency:"
        aggregate[:latency].each do |name, stats|
          ci = stats[:mean_ms_ci]
          little_ci = stats[:little_mean_ms_ci]
          lines << format(
            "  %-16s mean=%8.3fms  little=%8.3fms  ci=[%8.3f,%8.3f]  little_ci=[%8.3f,%8.3f]  completed=%d",
            name,
            stats[:mean_ms],
            stats[:little_mean_ms],
            ci[0],
            ci[1],
            little_ci[0],
            little_ci[1],
            stats[:completed_count]
          )
        end
      end

      lines << ""
      lines << "top targets:"
      lines << "  share  causal  verdict      samples  target  predicted improvement at 25% / 50% / 90%"
      aggregate[:targets].first(limit).each do |target|
        curve = target[:curve]
        i25 = curve.find { |point| point[:speedup_pct] == 25 }[:improvement_pct]
        i50 = curve.find { |point| point[:speedup_pct] == 50 }[:improvement_pct]
        i90 = curve.find { |point| point[:speedup_pct] == 90 }[:improvement_pct]
        lines << format(
          "  %5.1f%%  %5.1f%%  %-10s  %7d  %-62s  %6.2f%% / %6.2f%% / %6.2f%%",
          target[:sample_share] * 100.0,
          target[:causal_share].to_f * 100.0,
          target[:verdict],
          target[:samples],
          target_label(target),
          i25,
          i50,
          i90
        )
      end

      disagreements = disagreement_targets(aggregate[:targets]).first(5)
      unless disagreements.empty?
        lines << ""
        lines << "disagreement highlights:"
        disagreements.each do |target|
          lines << format(
            "  %-70s observed=%5.1f%% causal=%5.1f%% verdict=%s",
            target_label(target),
            target[:sample_share] * 100.0,
            target[:causal_share].to_f * 100.0,
            target[:verdict]
          )
        end
      end

      lines.join("\n")
    end

    def write_firefox(path)
      aggregate = @analysis.aggregate
      File.write(path, JSON.pretty_generate(FirefoxProfile.build(aggregate)))
    end

    def write_html(path, limit: 20)
      aggregate = @analysis.aggregate
      File.write(path, html_document(aggregate, limit))
    end

    private

    def format_seconds(ns)
      format("%.3fs", ns.to_f / 1_000_000_000)
    end

    def html_document(aggregate, limit)
      rows = aggregate[:targets].first(limit).map do |target|
        curve = target[:curve]
        i25 = curve.find { |point| point[:speedup_pct] == 25 }[:improvement_pct]
        i50 = curve.find { |point| point[:speedup_pct] == 50 }[:improvement_pct]
        i90 = curve.find { |point| point[:speedup_pct] == 90 }[:improvement_pct]

        <<~HTML
          <tr>
            <td>#{escape(target_label(target))}</td>
            <td>#{format("%.1f%%", target[:sample_share] * 100.0)}</td>
            <td>#{format("%.1f%%", target[:causal_share].to_f * 100.0)}</td>
            <td>#{escape(target[:verdict])}</td>
            <td>#{target[:samples]}</td>
            <td>#{format("%.2f%%", i25)}</td>
            <td>#{format("%.2f%%", i50)}</td>
            <td>#{format("%.2f%%", i90)}</td>
            <td>#{curve_svg(curve)}</td>
          </tr>
        HTML
      end.join

      latency_rows = aggregate[:latency].map do |name, stats|
        <<~HTML
          <tr>
            <td>#{escape(name)}</td>
            <td>#{format("%.3fms", stats[:mean_ms])}</td>
            <td>#{format("%.3fms", stats[:little_mean_ms])}</td>
            <td>#{format("[%.3f, %.3f]", *stats[:mean_ms_ci])}</td>
            <td>#{format("[%.3f, %.3f]", *stats[:little_mean_ms_ci])}</td>
            <td>#{stats[:completed_count]}</td>
          </tr>
        HTML
      end.join

      <<~HTML
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <title>corkscrews report</title>
          <style>
            body { font-family: system-ui, sans-serif; margin: 2rem; color: #1f2933; }
            table { border-collapse: collapse; width: 100%; }
            th, td { border-bottom: 1px solid #d8dee9; padding: 0.5rem; text-align: left; }
            th { background: #eef2f7; }
            .meta { margin-bottom: 1rem; color: #52606d; }
          </style>
        </head>
        <body>
          <h1>corkscrews report</h1>
          <p class="meta">runs: #{aggregate[:run_count]} samples: #{aggregate[:total_samples]} duration: #{format_seconds(aggregate[:duration_ns])}</p>
          <p class="meta">fiber switches: #{aggregate[:runtime][:fiber_switches]} max fibers: #{aggregate[:runtime][:max_fiber_count]} fiber threads: #{aggregate[:runtime][:fiber_thread_count]} scheduler: #{aggregate[:runtime][:fiber_scheduler]} max ractors: #{aggregate[:runtime][:max_ractor_count]}</p>
          <table>
            <thead>
              <tr>
                <th>Target</th>
                <th>Sample share</th>
                <th>Causal share</th>
                <th>Verdict</th>
                <th>Samples</th>
                <th>25% virtual speedup</th>
                <th>50% virtual speedup</th>
                <th>90% virtual speedup</th>
                <th>Curve</th>
              </tr>
            </thead>
            <tbody>
              #{rows}
            </tbody>
          </table>
          <h2>Latency</h2>
          <table>
            <thead>
              <tr>
                <th>Name</th>
                <th>Mean</th>
                <th>Little mean</th>
                <th>CI</th>
                <th>Little CI</th>
                <th>Completed</th>
              </tr>
            </thead>
            <tbody>
              #{latency_rows}
            </tbody>
          </table>
        </body>
        </html>
      HTML
    end

    def escape(value)
      CGI.escapeHTML(value.to_s)
    end

    def target_label(target)
      if target[:kind] == "wait"
        "wait:#{target[:name]}"
      else
        "#{target[:file]}:#{target[:line]}"
      end
    end

    def disagreement_targets(targets)
      targets.select do |target|
        target[:sample_share].to_f >= 0.05 && target[:causal_share].to_f <= target[:sample_share].to_f / 3.0
      end
    end

    def curve_svg(curve)
      max_y = [curve.map { |point| point[:improvement_pct].to_f }.max.to_f, 1.0].max
      points = curve.map do |point|
        x = (point[:speedup_pct].to_f / 95.0) * 160.0
        y = 40.0 - ((point[:improvement_pct].to_f / max_y) * 36.0)
        "#{format("%.1f", x)},#{format("%.1f", y)}"
      end.join(" ")

      %(<svg width="170" height="44" viewBox="0 0 170 44" role="img" aria-label="virtual speedup curve"><polyline points="#{points}" fill="none" stroke="#1f6feb" stroke-width="2"/></svg>)
    end

  end
end
