# frozen_string_literal: true

RSpec.describe Corkscrews do
  before(:context) do
    require "json"
    require "tempfile"
    require "corkscrews/analysis"
    require "corkscrews/controller"
    require "corkscrews/report"
    require "corkscrews/statistics"
  end

  it "has a version number" do
    expect(Corkscrews::VERSION).not_to be nil
  end

  it "exposes progress APIs" do
    expect { Corkscrews.progress(:spec) }.not_to raise_error
    expect { Corkscrews.latency_begin(:spec) }.not_to raise_error
    expect { Corkscrews.latency_end(:spec) }.not_to raise_error
  end

  it "computes medians for odd and even samples" do
    expect(Corkscrews::Statistics.median([3, 1, 2])).to eq(2.0)
    expect(Corkscrews::Statistics.median([4, 1, 2, 3])).to eq(2.5)
  end

  it "falls back from sparse round data to share-based curves" do
    events = [
      { "type" => "process", "pid" => 1, "run_id" => "r", "repeat_index" => 0, "duration_ns" => 1_000_000_000 },
      { "type" => "line", "pid" => 1, "run_id" => "r", "repeat_index" => 0,
        "target" => { "kind" => "line", "file" => "/tmp/app.rb", "line" => 10 },
        "samples" => 50, "causal_samples" => 50 },
      { "type" => "line", "pid" => 1, "run_id" => "r", "repeat_index" => 0,
        "target" => { "kind" => "line", "file" => "/tmp/app.rb", "line" => 11 },
        "samples" => 50, "causal_samples" => 50 },
      { "type" => "round", "pid" => 1, "run_id" => "r", "repeat_index" => 0,
        "target" => { "kind" => "line", "file" => "/tmp/app.rb", "line" => 10 },
        "speedup_pct" => 0, "baseline" => true, "visits" => 100,
        "physical_duration_ns" => 1_000_000_000, "virtual_duration_ns" => 1_000_000_000 },
      { "type" => "round", "pid" => 1, "run_id" => "r", "repeat_index" => 0,
        "target" => { "kind" => "line", "file" => "/tmp/app.rb", "line" => 10 },
        "speedup_pct" => 95, "baseline" => false, "visits" => 100,
        "physical_duration_ns" => 1_000_000_000, "virtual_duration_ns" => 100_000_000 }
    ]

    curve = Corkscrews::Analysis.new(events).target_curve(file: "/tmp/app.rb", line: 10)
    point = curve.find { |entry| entry[:speedup_pct] == 50 }
    expect(point[:improvement_pct]).to be_within(0.01).of(33.33333333333333)
  end

  it "exports aggregate samples in Firefox Profiler table form" do
    events = [
      { type: "process", pid: 1, run_id: "r", repeat_index: 0, duration_ns: 1_000_000_000 },
      { type: "line", pid: 1, run_id: "r", repeat_index: 0,
        target: { kind: "line", file: "/tmp/app.rb", line: 42 },
        samples: 3, causal_samples: 2 },
      { type: "round", pid: 1, run_id: "r", repeat_index: 0,
        target: { kind: "line", file: "/tmp/app.rb", line: 42 },
        speedup_pct: 25, baseline: false, visits: 3,
        physical_duration_ns: 100_000_000, virtual_duration_ns: 80_000_000 }
    ]

    Tempfile.create(["corkscrews-profile", ".ndjson"]) do |input|
      input.write(events.map(&:to_json).join("\n"))
      input.flush

      Tempfile.create(["corkscrews-firefox", ".json"]) do |output|
        Corkscrews::Report.new(input.path).write_firefox(output.path)

        profile = JSON.parse(File.read(output.path))
        thread = profile.fetch("threads").first

        expect(profile.fetch("meta").fetch("product")).to eq("corkscrews")
        expect(thread.fetch("samples").fetch("schema")).to include("stack" => 0, "time" => 1)
        expect(thread.fetch("samples").fetch("data").length).to eq(3)
        expect(thread.fetch("stackTable").fetch("data").first).to eq([nil, 0, 0, 0])
        expect(thread.fetch("frameTable").fetch("data").first[6]).to eq(42)
        expect(thread.fetch("stringArray")).to include("/tmp/app.rb:42")
        expect(thread.fetch("markers").fetch("data").first.last).to include(
          "target" => "/tmp/app.rb:42",
          "samples" => 3
        )
        expect(thread.fetch("markers").fetch("data").last.last).to include(
          "type" => "CorkscrewsRound",
          "speedupPct" => 25,
          "virtualDurationMs" => 80.0
        )
      end
    end
  end

  it "uses adaptive round planning to cover priority speedups" do
    controller = Corkscrews::Controller.new(
      targets: [{ kind: "line", file: "/tmp/app.rb", line: 42, sample_share: 0.8, causal_share: 0.8 }],
      random: Random.new(1)
    )
    first = controller.next_round(progress_visits: 10, duration_ns: 1_000_000_000, history: [])
    second = controller.next_round(
      progress_visits: 10,
      duration_ns: 1_000_000_000,
      history: [{ target: first.target, speedup_pct: first.speedup_pct }]
    )

    expect(first.speedup_pct).to eq(0)
    expect(second.speedup_pct).to eq(25)
    expect(second.virtual_duration_ns).to eq(800_000_000)
  end

  it "aggregates runtime fiber details and native thread-state gauges" do
    events = [
      { "type" => "process", "pid" => 1, "run_id" => "r1", "repeat_index" => 0, "duration_ns" => 1 },
      { "type" => "runtime", "pid" => 1, "run_id" => "r1", "repeat_index" => 0,
        "fiber_switches" => 2, "fiber_count" => 1, "fiber_thread_count" => 1, "ractor_count" => 1 },
      { "type" => "native", "pid" => 1, "run_id" => "r1", "repeat_index" => 0,
        "snapshot" => { "thread_live_count" => 2, "thread_max_live_count" => 3, "thread_state_running" => 1 } },
      { "type" => "process", "pid" => 1, "run_id" => "r2", "repeat_index" => 1, "duration_ns" => 1 },
      { "type" => "runtime", "pid" => 1, "run_id" => "r2", "repeat_index" => 1,
        "fiber_switches" => 4, "fiber_count" => 3, "fiber_thread_count" => 2, "ractor_count" => 2 },
      { "type" => "native", "pid" => 1, "run_id" => "r2", "repeat_index" => 1,
        "snapshot" => { "thread_live_count" => 1, "thread_max_live_count" => 4, "thread_state_running" => 2 } }
    ]

    aggregate = Corkscrews::Analysis.new(events).aggregate

    expect(aggregate[:runtime]).to include(
      fiber_switches: 6,
      max_fiber_count: 3,
      fiber_thread_count: 2,
      max_ractor_count: 2
    )
    expect(aggregate[:native]).to include(
      thread_live_count: 2,
      thread_max_live_count: 4,
      thread_state_running: 2
    )
  end
end
