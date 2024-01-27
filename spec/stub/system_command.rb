# frozen_string_literal: true

class SystemCommand
  module Mixin
    def system_command(*)
      OpenStruct.new(
        success?:      true,
        merged_output: "",
      )
    end
  end
end
