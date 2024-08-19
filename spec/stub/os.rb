# frozen_string_literal: true

module OS
  module_function

  def mac?
    RUBY_PLATFORM[/darwin/]
  end

  def linux?
    RUBY_PLATFORM[/linux/]
  end
end
