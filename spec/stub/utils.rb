# frozen_string_literal: true

def quiet_system(*) end

def system_command(*)
  OpenStruct.new(
    success?:      true,
    merged_output: "",
  )
end
module Formatter
  module_function

  def headline(*) end
end
