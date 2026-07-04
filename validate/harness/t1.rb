# frozen_string_literal: true

require_relative "../../lib/corkscrews/validate"

module Corkscrews
  module Validate
    module T1
      module_function

      def check!(manifest, profile, actual)
        Validate.t1_prediction_check(manifest, profile, actual)
      end
    end
  end
end
