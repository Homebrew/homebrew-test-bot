def quiet_system(*) end

def system_command(*)
  OpenStruct.new(
    success?:      true,
    merged_output: "",
  )
end

def oh1(*) end

module Formatter
  module_function

  def headline(*) end
end
