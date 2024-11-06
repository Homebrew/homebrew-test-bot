# frozen_string_literal: true

require "ostruct"

class Tap
  def self.fetch(*)
    OpenStruct.new(name: "Homebrew/homebrew-core")
  end

  def self.map
    []
  end
end

class CoreTap
  def self.instance
    Tap.fetch
  end
end
