# frozen_string_literal: true

require_relative "../../lib/corkscrews/validate"

module Corkscrews
  module Validate
    module T5
      module_function

      def check!
        Validate.t5_statistics_check
      end
    end
  end
end
