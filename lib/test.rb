# frozen_string_literal: true

module Homebrew
  class Test
    def failed_steps
      @steps.select(&:failed?)
    end

    def ignored_steps
      @steps.select(&:ignored?)
    end

    attr_reader :steps

    private

    attr_reader :tap, :git, :repository

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

    def test_header(klass, method: "run!")
      puts
      puts Formatter.headline("Running #{klass}##{method}", color: :magenta)
    end

    def info_header(text)
      puts Formatter.headline(text, color: :cyan)
    end

    def test(*arguments, named_args: nil, env: {}, verbose: @verbose, ignore_failures: false)
      step = Step.new(
        arguments,
        named_args:      named_args,
        env:             env,
        verbose:         verbose,
        ignore_failures: ignore_failures,
        repository:      @repository,
      )
      step.run(dry_run: @dry_run, fail_fast: @fail_fast)
      @steps << step
      step
    end
  end
end
