# frozen_string_literal: true

require "ostruct"

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
