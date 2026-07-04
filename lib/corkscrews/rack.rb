# frozen_string_literal: true

require_relative "../corkscrews"

module Corkscrews
  class Rack
    def initialize(app, progress_name: :rack_request)
      @app = app
      @progress_name = progress_name
    end

    def call(env)
      Corkscrews.latency_begin(@progress_name)
      status, headers, body = @app.call(env)
      Corkscrews.progress(@progress_name)
      [status, headers, ResponseBody.new(body, @progress_name)]
    rescue Exception
      Corkscrews.latency_end(@progress_name)
      raise
    end

    class ResponseBody
      def initialize(body, progress_name)
        @body = body
        @progress_name = progress_name
      end

      def each(&block)
        @body.each(&block)
      end

      def close
        @body.close if @body.respond_to?(:close)
      ensure
        Corkscrews.latency_end(@progress_name)
      end
    end
  end
end
