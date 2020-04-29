# frozen_string_literal: true

module Homebrew
  class Test
    attr_reader :steps

    protected

    def initialize
      # TODO: move code from subclasses here
    end

    def method_header(method, klass: "Test")
      @category = method
      puts
      puts Formatter.headline("Running #{klass}##{method}", color: :magenta)
    end

    def test(*args, env: {}, verbose: Homebrew.args.verbose?)
      step = Step.new(args, env: env, verbose: verbose)
      step.run
      @steps << step
      step
    end
  end
end
