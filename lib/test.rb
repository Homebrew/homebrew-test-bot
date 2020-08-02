# frozen_string_literal: true

module Homebrew
  class Test
    def failed_steps
      @steps.select(&:failed?)
    end

    protected

    attr_reader :tap, :git, :steps, :repository

    def initialize(tap: nil, git: nil, dry_run: false, fail_fast: false, verbose: false)
      @tap = tap
      @git = git
      @dry_run = dry_run
      @fail_fast = fail_fast
      @verbose = verbose

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

    def test(*arguments, env: {}, verbose: @verbose)
      step = Step.new(arguments, env: env, verbose: verbose)
      step.run(dry_run: @dry_run, fail_fast: @fail_fast)
      @steps << step
      step
    end
  end
end
