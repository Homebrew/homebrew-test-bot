# frozen_string_literal: true

module Homebrew
  class Test
    def failed_steps
      @steps.select(&:failed?)
    end

    protected

    attr_reader :tap, :git, :steps, :repository

    def initialize(tap: nil, git: nil)
      @tap = tap
      @git = git

      @steps = []

      @repository = if @tap
        @tap.path
      else
        CoreTap.instance.path
      end
    end

    def change_git!(git)
      @git = git
    end

    def test_header(klass, method: "run!")
      puts
      puts Formatter.headline("Running #{klass}##{method}", color: :magenta)
    end

    def test(*arguments, env: {}, args:, verbose: args.verbose?)
      step = Step.new(arguments, env: env, verbose: verbose)
      step.run(dry_run: args.dry_run?, fail_fast: args.fail_fast?)
      @steps << step
      step
    end
  end
end
