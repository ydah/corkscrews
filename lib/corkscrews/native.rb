# frozen_string_literal: true

begin
  require "corkscrews/corkscrews"
rescue LoadError
  begin
    require_relative "../../ext/corkscrews/corkscrews"
  rescue LoadError
    nil
  end
end

module Corkscrews
  module Native
    @stamps = ObjectSpace::WeakMap.new

    module_function

    def available?
      defined?(Corkscrews::NativeExtension::AVAILABLE) && Corkscrews::NativeExtension::AVAILABLE
    end

    def settled_now
      return Corkscrews::Delay.settled_now if defined?(Corkscrews::Delay)

      Thread.current[:corkscrews_settled_stamp_ns] ||= 0
    end

    def stamp_write(object)
      if defined?(Corkscrews::Delay)
        Corkscrews::Delay.stamp_write(object)
        return nil
      end

      @stamps[object] = settled_now
    end

    def stamp_inherit(object)
      if defined?(Corkscrews::Delay)
        Corkscrews::Delay.stamp_inherit(object)
        return nil
      end

      stamp = @stamps[object].to_i
      current = settled_now
      Thread.current[:corkscrews_settled_stamp_ns] = [current, stamp].max
    end

    def install_hooks!
      Corkscrews::Hooks.install! if defined?(Corkscrews::Hooks)
    end

    def start_monitor
      Corkscrews::Monitor.start! if defined?(Corkscrews::Monitor)
    end

    def stop_monitor
      Corkscrews::Monitor.stop! if defined?(Corkscrews::Monitor)
    end

    def monitor_available?
      defined?(Corkscrews::Monitor) &&
        Corkscrews::Monitor.respond_to?(:available?) &&
        Corkscrews::Monitor.available?
    end

    def register_monitor_thread
      Corkscrews::Monitor.register_current_thread! if defined?(Corkscrews::Monitor) && Corkscrews::Monitor.respond_to?(:register_current_thread!)
    end

    def clear_monitor_thread
      Corkscrews::Monitor.clear_current_thread! if defined?(Corkscrews::Monitor) && Corkscrews::Monitor.respond_to?(:clear_current_thread!)
    end

    def native_snapshot
      return {} unless defined?(Corkscrews::Record)

      Corkscrews::Record.snapshot
    end

    def native_events
      return [] unless defined?(Corkscrews::Record) && Corkscrews::Record.respond_to?(:events)

      Corkscrews::Record.events
    end

    def set_experiment(kind:, iseq: 0, line: 0, speedup_pct: 0)
      return unless defined?(Corkscrews::Delay)

      kind_id = { none: 0, line: 1, wait: 2 }.fetch(kind.to_sym, 0)
      Corkscrews::Delay.set_experiment(kind_id, iseq.to_i, line.to_i, speedup_pct.to_i)
    end

    def set_sample_period(ns)
      Corkscrews::Delay.set_sample_period(ns.to_i) if defined?(Corkscrews::Delay)
    end

    def clear_experiment
      Corkscrews::Delay.clear_experiment if defined?(Corkscrews::Delay)
    end

    def settle_current
      return Corkscrews::Delay.settle_current if defined?(Corkscrews::Delay)

      0
    end
  end
end
