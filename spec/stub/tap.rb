# frozen_string_literal: true

module Tap
  module_function

  def fetch(*)
    OpenStruct.new(name: "Homebrew/homebrew-core")
  end

  def map
    []
  end
end

class CoreTap
  def self.instance
    Tap.fetch
  end
end
