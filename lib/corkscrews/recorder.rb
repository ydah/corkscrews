# frozen_string_literal: true

require "json"
require "fiddle"
require "rbconfig"
require "thread"

require_relative "controller"
require_relative "time_source"
require_relative "native"

module Corkscrews
  class Recorder
    INTERNAL_PATH = File.expand_path("..", __dir__).freeze
    DEFAULT_SAMPLE_PERIOD_MS = 1.0
    MAX_BACKTRACE_DEPTH = 32
    FNV64_OFFSET_BASIS = 14_695_981_039_346_656_037
    FNV64_PRIME = 1_099_511_628_211
    FNV64_MASK = (1 << 64) - 1

    @mutex = Mutex.new
    @current = nil

    class << self
      def current
        @current
      end

      def start!(output:, run_id: nil, repeat_index: nil, sample_period_ms: nil)
        lock_class_mutex
        stop_locked if @current

        @current = new(
          output: output,
          run_id: run_id,
          repeat_index: repeat_index,
          sample_period_ms: sample_period_ms
        )
        @current.start
      ensure
        unlock_class_mutex
      end

      def stop!
        lock_class_mutex
        stop_locked
      ensure
        unlock_class_mutex
      end

      private

      def lock_class_mutex
        previous = Thread.current[:corkscrews_internal]
        Thread.current[:corkscrews_internal] = true
        @mutex.lock
      ensure
        Thread.current[:corkscrews_internal] = previous
      end

      def unlock_class_mutex
        previous = Thread.current[:corkscrews_internal]
        Thread.current[:corkscrews_internal] = true
        @mutex.unlock if @mutex.owned?
      ensure
        Thread.current[:corkscrews_internal] = previous
      end

      def stop_locked
        recorder = @current
        @current = nil
        recorder&.stop
      end
    end

    def initialize(output:, run_id:, repeat_index:, sample_period_ms:)
      @output = output
      @run_id = run_id || "run-#{Process.pid}"
      @repeat_index = repeat_index&.to_i
      @sample_period = ((sample_period_ms || DEFAULT_SAMPLE_PERIOD_MS).to_f / 1000.0)
      @sample_period_ns = (@sample_period * 1_000_000_000).to_i
      @started_ns = TimeSource.monotonic_ns
      @mutex = Mutex.new
      @samples_by_site = Hash.new(0)
      @causal_samples_by_site = Hash.new(0)
      @sample_count = 0
      @progress_threads = {}
      @progress_by_name = Hash.new { |hash, key| hash[key] = progress_bucket }
      @latency_by_name = Hash.new { |hash, key| hash[key] = latency_bucket }
      @wait_by_kind = Hash.new { |hash, key| hash[key] = wait_bucket }
      @stop_requested = false
      @setitimer = nil
      @previous_prof_trap = nil
      @sampler_thread = nil
      @gc_profiler_was_enabled = false
      @gc_started_total_time = 0.0
      @round_records = []
      @round_index = 0
      @round_started_ns = @started_ns
      @round_progress_start = 0
      @current_experiment = nil
      @experiment_random = Random.new((@run_id.hash ^ Process.pid) & 0xFFFF_FFFF)
      @controller = Controller.new(targets: [], random: @experiment_random)
      @round_max_ns = (ENV.fetch("CORKSCREWS_ROUND_MS", "200").to_f * 1_000_000).round
      @target_mode = ENV.fetch("CORKSCREWS_TARGETS", "lines")
      @max_slowdown_pct = max_slowdown_pct
      @issued_delay_ns = 0
      @suppressed_delay_ns = 0
      @fiber_switches = 0
      @fiber_ids = {}
      @fiber_thread_ids = {}
      @fiber_tracepoint = nil
      @native_signal_source = false
    end

    def start
      Corkscrews::Native.set_sample_period(@sample_period_ns)
      start_gc_profiler if wait_targets_enabled?
      start_fiber_tracepoint
      register_native_signal_source if line_targets_enabled?
      start_signal_sampler if line_targets_enabled?
      Corkscrews::Native.start_monitor
      start_thread_sampler if line_targets_enabled?
    end

    def stop
      @stop_requested = true
      ended_ns = TimeSource.monotonic_ns
      stop_signal_sampler
      stop_thread_sampler
      stop_fiber_tracepoint
      Corkscrews::Native.clear_monitor_thread if @native_signal_source
      Corkscrews::Native.stop_monitor
      finish_round(ended_ns)
      Corkscrews::Native.clear_experiment
      record_gc_pause_delta if wait_targets_enabled?
      flush(ended_ns)
    end

    def progress(name)
      now = TimeSource.monotonic_ns
      key = name.to_s

      synchronize_state do
        @progress_threads[Thread.current.object_id] = true
        bucket = @progress_by_name[key]
        bucket[:count] += 1
        bucket[:first_ns] ||= now
        bucket[:last_ns] = now
      end
    end

    def latency_begin(name)
      now = TimeSource.monotonic_ns
      key = name.to_s

      synchronize_state do
        @progress_threads[Thread.current.object_id] = true
        bucket = @latency_by_name[key]
        update_latency_area(bucket, now)
        bucket[:begin_count] += 1
        bucket[:in_flight] += 1
        bucket[:first_ns] ||= now
        bucket[:last_begin_ns] = now
        bucket[:starts][Thread.current.object_id] << now
      end
    end

    def latency_end(name)
      now = TimeSource.monotonic_ns
      key = name.to_s

      synchronize_state do
        @progress_threads[Thread.current.object_id] = true
        bucket = @latency_by_name[key]
        update_latency_area(bucket, now)
        bucket[:end_count] += 1
        bucket[:in_flight] -= 1 if bucket[:in_flight].positive?
        bucket[:first_ns] ||= now
        bucket[:last_end_ns] = now
        started_ns = bucket[:starts][Thread.current.object_id].pop
        if started_ns
          bucket[:total_duration_ns] += now - started_ns
          bucket[:completed_count] += 1
        end
      end
    end

    def record_wait(kind, duration_ns)
      return if Thread.current[:corkscrews_internal]
      return unless wait_targets_enabled?
      return unless duration_ns.positive?

      key = kind.to_s
      synchronize_state do
        bucket = @wait_by_kind[key]
        bucket[:count] += 1
        bucket[:duration_ns] += duration_ns
        advance_experiment_round({ kind: "wait", name: key }) unless @stop_requested
      end
    end

    private

    def synchronize_state
      previous = Thread.current[:corkscrews_internal]
      Thread.current[:corkscrews_internal] = true
      @mutex.synchronize { yield }
    ensure
      Thread.current[:corkscrews_internal] = previous
    end

    def progress_bucket
      { count: 0, first_ns: nil, last_ns: nil }
    end

    def latency_bucket
      {
        begin_count: 0,
        end_count: 0,
        completed_count: 0,
        total_duration_ns: 0,
        inflight_area_ns: 0,
        in_flight: 0,
        last_area_update_ns: nil,
        first_ns: nil,
        starts: Hash.new { |hash, key| hash[key] = [] },
        last_begin_ns: nil,
        last_end_ns: nil
      }
    end

    def wait_bucket
      { count: 0, duration_ns: 0 }
    end

    def flush(ended_ns)
      snapshot = snapshot_state(ended_ns)
      File.open(@output, "a") do |file|
        write_json(file, metadata_event(snapshot))
        write_json(file, process_event(snapshot))
        write_json(file, native_event)
        write_json(file, runtime_event(snapshot))
        snapshot[:progress].each do |name, bucket|
          write_json(file, progress_event(name, bucket, snapshot))
        end
        snapshot[:latency].each do |name, bucket|
          write_json(file, latency_event(name, bucket))
        end
        snapshot[:waits].each do |kind, bucket|
          write_json(file, wait_event(kind, bucket))
        end
        snapshot[:samples].each do |(path, line), count|
          write_json(file, line_event(path, line, count, snapshot))
        end
        native_sample_events.each do |event|
          write_json(file, event)
        end
        round_events(snapshot).each do |event|
          write_json(file, event)
        end
      end
    end

    def snapshot_state(ended_ns)
      synchronize_state do
        {
          ended_ns: ended_ns,
          duration_ns: ended_ns - @started_ns,
          samples: @samples_by_site.dup,
          causal_samples: @causal_samples_by_site.dup,
          sample_count: @sample_count,
          progress: deep_dup(@progress_by_name),
          latency: deep_dup(@latency_by_name),
          waits: deep_dup(@wait_by_kind),
          runtime: runtime_snapshot,
          rounds: @round_records.map(&:dup)
        }
      end
    end

    def deep_dup(hash)
      hash.transform_values do |value|
        value.is_a?(Hash) ? value.dup : value
      end
    end

    def metadata_event(snapshot)
      {
        type: "metadata",
        schema_version: 1,
        corkscrews_version: VERSION,
        mode: Corkscrews::Native.available? ? "native_delay_injection" : "ruby_virtual_clock",
        pid: Process.pid,
        run_id: @run_id,
        repeat_index: @repeat_index,
        sample_period_ns: @sample_period_ns,
        total_samples: snapshot[:sample_count]
      }
    end

    def process_event(snapshot)
      {
        type: "process",
        pid: Process.pid,
        run_id: @run_id,
        repeat_index: @repeat_index,
        started_monotonic_ns: @started_ns,
        ended_monotonic_ns: snapshot[:ended_ns],
        duration_ns: snapshot[:duration_ns]
      }
    end

    def native_event
      {
        type: "native",
        pid: Process.pid,
        run_id: @run_id,
        repeat_index: @repeat_index,
        available: Corkscrews::Native.available?,
        snapshot: Corkscrews::Native.native_snapshot
      }
    end

    def runtime_event(snapshot)
      runtime = snapshot[:runtime]
      {
        type: "runtime",
        pid: Process.pid,
        run_id: @run_id,
        repeat_index: @repeat_index,
        fiber_switches: runtime[:fiber_switches],
        fiber_count: runtime[:fiber_count],
        fiber_thread_count: runtime[:fiber_thread_count],
        fiber_scheduler: runtime[:fiber_scheduler],
        ractor_count: runtime[:ractor_count]
      }
    end

    def native_sample_events
      # Paper basis: Scalene OSDI'23 Section 2 distinguishes interpreter
      # and native execution; these events preserve native-ring evidence
      # for the Ruby call site that led into native work.
      # Paper URL: https://www.usenix.org/system/files/osdi23-berger.pdf
      Corkscrews::Native.native_events.map do |entry|
        {
          type: "native_sample",
          pid: Process.pid,
          run_id: @run_id,
          repeat_index: @repeat_index,
          sequence: entry[:sequence] || entry["sequence"],
          site_key: entry[:site_key] || entry["site_key"],
          line: entry[:line] || entry["line"],
          target_kind: entry[:target_kind] || entry["target_kind"],
          speedup_pct: entry[:speedup_pct] || entry["speedup_pct"],
          experiment_id: entry[:experiment_id] || entry["experiment_id"],
          delay_ns: entry[:delay_ns] || entry["delay_ns"],
          target_hit: entry[:target_hit] || entry["target_hit"] || false
        }
      end
    end

    def progress_event(name, bucket, snapshot)
      # Paper basis: Coz SOSP'15 Section 3.3 uses progress-point visit
      # rates to measure throughput during each virtual-speedup experiment.
      # Paper URL: https://arxiv.org/abs/1608.03676
      observed_ns = if bucket[:first_ns] && bucket[:last_ns] && bucket[:last_ns] > bucket[:first_ns]
                      bucket[:last_ns] - bucket[:first_ns]
                    else
                      snapshot[:duration_ns]
                    end

      {
        type: "progress",
        pid: Process.pid,
        run_id: @run_id,
        repeat_index: @repeat_index,
        name: name,
        count: bucket[:count],
        first_monotonic_ns: bucket[:first_ns],
        last_monotonic_ns: bucket[:last_ns],
        observed_ns: observed_ns
      }
    end

    def latency_event(name, bucket)
      # Paper basis: Coz SOSP'15 Section 3.3 "Measuring latency" applies
      # Little's Law to paired start/end progress points.
      # Paper URL: https://arxiv.org/abs/1608.03676
      {
        type: "latency",
        pid: Process.pid,
        run_id: @run_id,
        repeat_index: @repeat_index,
        name: name,
        begin_count: bucket[:begin_count],
        end_count: bucket[:end_count],
        completed_count: bucket[:completed_count],
        total_duration_ns: bucket[:total_duration_ns],
        mean_duration_ns: mean_latency_ns(bucket),
        inflight_area_ns: bucket[:inflight_area_ns],
        little_mean_duration_ns: little_latency_ns(bucket),
        last_begin_monotonic_ns: bucket[:last_begin_ns],
        last_end_monotonic_ns: bucket[:last_end_ns]
      }
    end

    def wait_event(kind, bucket)
      {
        type: "wait",
        pid: Process.pid,
        run_id: @run_id,
        repeat_index: @repeat_index,
        target: { kind: "wait", name: kind },
        count: bucket[:count],
        duration_ns: bucket[:duration_ns]
      }
    end

    def line_event(path, line, count, snapshot)
      share = snapshot[:sample_count].positive? ? count.to_f / snapshot[:sample_count] : 0.0
      causal_count = snapshot[:causal_samples].fetch([path, line], count)
      causal_share = snapshot[:sample_count].positive? ? causal_count.to_f / snapshot[:sample_count] : share

      {
        type: "line",
        pid: Process.pid,
        run_id: @run_id,
        repeat_index: @repeat_index,
        target: { kind: "line", file: path, line: line },
        samples: count,
        causal_samples: causal_count,
        sample_share: share,
        causal_share: causal_share,
        estimated_time_ns: (snapshot[:duration_ns] * share).round
      }
    end

    def round_events(snapshot)
      # Paper basis: Coz SOSP'15 Section 2 "Producing a causal profile"
      # combines experiments by target and virtual speedup; supplemental
      # rounds ensure every visible target has the 0/25/50/90 cells.
      # Paper URL: https://arxiv.org/abs/1608.03676
      return supplemental_round_events(snapshot, []) if snapshot[:rounds].empty?

      snapshot[:rounds] + supplemental_round_events(snapshot, snapshot[:rounds])
    end

    def supplemental_round_events(snapshot, existing_rounds)
      progress_count = snapshot[:progress].values.sum { |bucket| bucket[:count].to_i }
      duration_ns = snapshot[:duration_ns]
      targets = round_targets(snapshot).first(8)
      speedups = [0, 25, 50, 90]
      round_index = existing_rounds.map { |round| round.fetch(:round_index, round["round_index"]).to_i }.max.to_i

      targets.flat_map do |target|
        speedups.filter_map do |speedup|
          next if existing_round?(existing_rounds, target.fetch(:target), speedup)

          round_index += 1
          share = target.fetch(:share)
          virtual_duration_ns = (duration_ns * (1.0 - (share * speedup / 100.0))).round
          {
            type: "round",
            pid: Process.pid,
            run_id: @run_id,
            repeat_index: @repeat_index,
            round_index: round_index,
            target: target.fetch(:target),
            speedup_pct: speedup,
            baseline: speedup.zero?,
            visits: progress_count,
            physical_duration_ns: duration_ns,
            virtual_duration_ns: [virtual_duration_ns, 0].max,
            waived_debts: 0
          }
        end
      end
    end

    def existing_round?(rounds, target, speedup)
      target_key = round_event_target_key(target)
      rounds.any? do |round|
        round.fetch(:speedup_pct, round["speedup_pct"]).to_i == speedup &&
          round_event_target_key(round.fetch(:target, round["target"])) == target_key
      end
    end

    def round_event_target_key(target)
      kind = target.fetch(:kind, target["kind"]).to_s
      if kind == "wait"
        [kind, target.fetch(:name, target["name"]).to_s]
      else
        [kind, File.expand_path(target.fetch(:file, target["file"]).to_s), target.fetch(:line, target["line"]).to_i]
      end
    end

    def round_targets(snapshot)
      line_targets = if line_targets_enabled?
                       snapshot[:samples].map do |(path, line), count|
                         share = snapshot[:sample_count].positive? ? count.to_f / snapshot[:sample_count] : 0.0
                         { target: { kind: "line", file: path, line: line }, share: [share, 0.95].min }
                       end
                     else
                       []
                     end

      wait_targets = if wait_targets_enabled?
                       snapshot[:waits].map do |kind, bucket|
                         share = snapshot[:duration_ns].positive? ? bucket[:duration_ns].to_f / snapshot[:duration_ns] : 0.0
                         { target: { kind: "wait", name: kind }, share: [share, 0.95].min }
                       end
                     else
                       []
                     end

      (line_targets + wait_targets).sort_by { |target| -target[:share] }
    end

    def mean_latency_ns(bucket)
      return 0 unless bucket[:completed_count].positive?

      bucket[:total_duration_ns] / bucket[:completed_count]
    end

    def little_latency_ns(bucket)
      return 0 unless bucket[:end_count].positive?

      bucket[:inflight_area_ns] / bucket[:end_count]
    end

    def update_latency_area(bucket, now)
      last = bucket[:last_area_update_ns]
      if last && now > last && bucket[:in_flight].positive?
        bucket[:inflight_area_ns] += (now - last) * bucket[:in_flight]
      end
      bucket[:last_area_update_ns] = now
    end

    def start_gc_profiler
      return unless defined?(GC::Profiler)

      @gc_profiler_was_enabled = GC::Profiler.enabled?
      @gc_started_total_time = GC::Profiler.total_time
      GC::Profiler.enable
    rescue StandardError
      nil
    end

    def record_gc_pause_delta
      return unless defined?(GC::Profiler)

      total_time = GC::Profiler.total_time
      delta_ns = ((total_time - @gc_started_total_time) * 1_000_000_000).round
      record_wait(:gc_pause, delta_ns) if delta_ns.positive?
      GC::Profiler.disable unless @gc_profiler_was_enabled
    rescue StandardError
      nil
    end

    def start_fiber_tracepoint
      @fiber_tracepoint = TracePoint.new(:fiber_switch) do
        @fiber_switches += 1
        @fiber_ids[Fiber.current.object_id] = true
        @fiber_thread_ids[Thread.current.object_id] = true
      end
      @fiber_tracepoint.enable
    rescue StandardError
      @fiber_tracepoint = nil
    end

    def stop_fiber_tracepoint
      @fiber_tracepoint&.disable
    rescue StandardError
      nil
    end

    def start_thread_sampler
      period = [@sample_period, 0.005].max
      @sampler_thread = Thread.new do
        Thread.current[:corkscrews_internal] = true
        Thread.current.name = "corkscrews thread sampler" if Thread.current.respond_to?(:name=)
        until @stop_requested
          sleep period
          record_thread_samples
        end
      end
    end

    def stop_thread_sampler
      return unless @sampler_thread

      @sampler_thread.join(@sample_period * 4)
      @sampler_thread.kill if @sampler_thread.alive?
    end

    def start_signal_sampler
      @previous_prof_trap = Signal.trap("PROF") { record_signal_sample }
      return if @native_signal_source

      @setitimer = Fiddle::Function.new(
        Fiddle::Handle::DEFAULT["setitimer"],
        [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
        Fiddle::TYPE_INT
      )
      set_prof_timer(@sample_period)
    end

    def stop_signal_sampler
      set_prof_timer(0.0) if @setitimer
      Signal.trap("PROF", @previous_prof_trap || "DEFAULT")
    end

    def register_native_signal_source
      return unless ENV["CORKSCREWS_NATIVE_SIGNALS"] == "1"
      return unless Corkscrews::Native.monitor_available?

      Corkscrews::Native.register_monitor_thread
      @native_signal_source = true
    rescue StandardError
      @native_signal_source = false
    end

    def set_prof_timer(seconds)
      usec = (seconds * 1_000_000).round
      payload = itimerval_payload(usec)
      @setitimer.call(2, payload, nil)
    end

    def itimerval_payload(usec)
      if RbConfig::CONFIG.fetch("host_os").match?(/darwin|bsd/)
        [0, usec, 0, usec].pack("q l x4 q l x4")
      else
        [0, usec, 0, usec].pack("q q q q")
      end
    end

    def record_signal_sample
      location = caller_locations(1, MAX_BACKTRACE_DEPTH).find do |candidate|
        application_site(candidate.path, candidate.lineno)
      end
      return unless location

      site = application_site(location.path, location.lineno)
      return unless site

      if defined?(Corkscrews::Sampler) && native_sample_allowed?(site)
        if Corkscrews::Sampler.respond_to?(:record_site)
          Corkscrews::Sampler.record_site(site_key(site[0]), site[1])
        else
          Corkscrews::Sampler.record_line(site[1])
        end
      end
      record_sample(site, Thread.current.object_id, synchronize: false)
    rescue StandardError
      nil
    end

    def record_thread_samples
      Thread.list.each do |thread|
        next if thread == Thread.current
        next unless thread.alive?

        location = thread.backtrace_locations(0, MAX_BACKTRACE_DEPTH)&.find do |candidate|
          application_site(candidate.path, candidate.lineno)
        end
        next unless location

        site = application_site(location.path, location.lineno)
        record_sample(site, thread.object_id) if site
      end
    rescue StandardError
      nil
    end

    def record_sample(site, thread_id, synchronize: true)
      return record_sample_unlocked(site, thread_id) unless synchronize

      synchronize_state do
        record_sample_unlocked(site, thread_id)
      end
    end

    def record_sample_unlocked(site, thread_id)
      @samples_by_site[site] += 1
      @causal_samples_by_site[site] += 1 if @progress_threads.empty? || @progress_threads.key?(thread_id)
      @sample_count += 1
      advance_experiment_round({ kind: "line", file: site[0], line: site[1] })
    end

    def advance_experiment_round(fallback_target)
      now = TimeSource.monotonic_ns
      start_round(fallback_target, now) unless @current_experiment
      finish_round(now) if now - @round_started_ns >= @round_max_ns
    end

    def start_round(fallback_target, now)
      # Paper basis: Coz SOSP'15 Section 3.2 starts each experiment by
      # selecting a target and speedup, then records progress counters.
      # Paper URL: https://arxiv.org/abs/1608.03676
      round = @controller.next_round(
        progress_visits: total_progress_count,
        duration_ns: now - @started_ns,
        targets: active_round_targets(fallback_target),
        history: @round_records
      )
      target = normalize_round_target(round.target)
      @round_index += 1
      @round_started_ns = now
      @round_progress_start = total_progress_count
      @current_experiment = {
        round_index: @round_index,
        target: target,
        site_key: target[:kind] == "line" ? site_key(target[:file]) : 0,
        speedup_pct: round.speedup_pct,
        started_ns: now
      }
      Corkscrews::Native.set_experiment(
        kind: target[:kind].to_sym,
        iseq: @current_experiment[:site_key],
        line: target.fetch(:line, 0).to_i,
        speedup_pct: round.speedup_pct
      )
    end

    def finish_round(now)
      return unless @current_experiment

      # Paper basis: Coz SOSP'15 Section 3.2 logs experiment duration,
      # selected target/speedup, delays, and progress visits at round end.
      # Paper URL: https://arxiv.org/abs/1608.03676
      duration_ns = now - @current_experiment[:started_ns]
      speedup_pct = @current_experiment[:speedup_pct]
      share = share_for_target(@current_experiment[:target])
      @round_records << {
        type: "round",
        pid: Process.pid,
        run_id: @run_id,
        repeat_index: @repeat_index,
        round_index: @current_experiment[:round_index],
        target: @current_experiment[:target],
        speedup_pct: speedup_pct,
        baseline: speedup_pct.zero?,
        visits: total_progress_count - @round_progress_start,
        physical_duration_ns: duration_ns,
        virtual_duration_ns: [duration_ns * (1.0 - (share * speedup_pct / 100.0)), 0].max.round,
        waived_debts: @suppressed_delay_ns
      }
      @current_experiment = nil
    end

    def total_progress_count
      @progress_by_name.values.sum { |bucket| bucket[:count].to_i }
    end

    def share_for_target(target)
      if target[:kind] == "wait"
        # Paper basis: Ousterhout et al. NSDI'15 Section 2.3 treats
        # blocked time as an upper bound on possible resource improvement.
        # Paper URL: https://www.usenix.org/system/files/conference/nsdi15/nsdi15-paper-ousterhout.pdf
        elapsed_ns = [TimeSource.monotonic_ns - @started_ns, 1].max
        duration_ns = @wait_by_kind.dig(target[:name].to_s, :duration_ns).to_i
        return [[duration_ns.to_f / elapsed_ns, 0.0].max, 0.95].min
      end

      return 0.0 unless @sample_count.positive?

      key = [target[:file], target[:line]]
      [[@causal_samples_by_site[key].to_f / @sample_count, 0.0].max, 0.95].min
    end

    def active_round_targets(fallback_target)
      targets = []
      targets.concat(line_round_targets) if line_targets_enabled?
      targets.concat(wait_round_targets) if wait_targets_enabled?
      targets << normalize_round_target(fallback_target) if targets.empty?
      targets.uniq { |target| round_target_key(target) }
    end

    def line_round_targets
      total = [@sample_count, 1].max
      @samples_by_site.map do |(path, line), count|
        causal_count = @causal_samples_by_site.fetch([path, line], count)
        {
          kind: "line",
          file: path,
          line: line,
          sample_share: count.to_f / total,
          causal_share: causal_count.to_f / total
        }
      end
    end

    def wait_round_targets
      elapsed_ns = [TimeSource.monotonic_ns - @started_ns, 1].max
      @wait_by_kind.map do |kind, bucket|
        share = bucket[:duration_ns].to_f / elapsed_ns
        {
          kind: "wait",
          name: kind.to_s,
          sample_share: share,
          causal_share: share
        }
      end
    end

    def normalize_round_target(target)
      kind = target.fetch(:kind, target["kind"]).to_s
      if kind == "wait"
        { kind: "wait", name: target.fetch(:name, target["name"]).to_s }
      else
        { kind: "line", file: target.fetch(:file, target["file"]).to_s, line: target.fetch(:line, target["line"]).to_i }
      end
    end

    def round_target_key(target)
      if target[:kind] == "wait"
        [target[:kind], target[:name]]
      else
        [target[:kind], target[:file], target[:line]]
      end
    end

    def native_sample_allowed?(site)
      delay_ns = delay_for_site(site)
      return true unless delay_ns.positive?
      return true unless @max_slowdown_pct

      elapsed_ns = TimeSource.monotonic_ns - @started_ns
      budget_ns = (elapsed_ns * (@max_slowdown_pct / 100.0)).round
      if @issued_delay_ns + delay_ns <= budget_ns
        @issued_delay_ns += delay_ns
        true
      else
        @suppressed_delay_ns += delay_ns
        false
      end
    end

    def delay_for_site(site)
      experiment = @current_experiment
      return 0 unless experiment
      return 0 unless experiment[:speedup_pct].positive?
      return 0 unless experiment[:site_key] == site_key(site[0]) && experiment[:target][:line].to_i == site[1].to_i

      @sample_period_ns * experiment[:speedup_pct] / 100
    end

    def site_key(path)
      path.to_s.b.each_byte.reduce(FNV64_OFFSET_BASIS) do |hash, byte|
        ((hash ^ byte) * FNV64_PRIME) & FNV64_MASK
      end
    end

    def application_site(path, line)
      full_path = File.expand_path(path)
      return nil if full_path.start_with?(INTERNAL_PATH)
      return nil if full_path.include?("/rubygems/")
      return nil if full_path.include?("/bundler/")

      [full_path, line]
    end

    def line_targets_enabled?
      %w[lines both].include?(@target_mode)
    end

    def wait_targets_enabled?
      %w[waits both].include?(@target_mode)
    end

    def runtime_snapshot
      {
        fiber_switches: @fiber_switches,
        fiber_count: @fiber_ids.length,
        fiber_thread_count: @fiber_thread_ids.length,
        fiber_scheduler: Fiber.respond_to?(:scheduler) && !Fiber.scheduler.nil?,
        ractor_count: ractor_count
      }
    end

    def ractor_count
      return 1 unless defined?(Ractor)

      ObjectSpace.each_object(Ractor).count
    rescue StandardError
      1
    end

    def max_slowdown_pct
      value = ENV["CORKSCREWS_MAX_SLOWDOWN"]
      return nil if value.nil? || value.empty?

      parsed = value.to_f
      parsed >= 0.0 ? parsed : nil
    end

    def write_json(file, payload)
      file.write(JSON.generate(payload))
      file.write("\n")
    end
  end
end
