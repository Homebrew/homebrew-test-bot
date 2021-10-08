# frozen_string_literal: true

module Homebrew
  class Test
    def failed_steps
      @steps.select(&:failed?)
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

    def pending_steps
      steps.select(&:pending?)
    end

    def resolve_pending(passed: nil)
      return unless pending_steps.present?

      info_header "Determining status of pending tests..."

      @steps.select(&:pending?).each do |s|
        s.resolve_pending(passed: passed)
      end

      exit 1 if @fail_fast && @steps.any?(&:failed?)
    end

    def test_header(klass, method: "run!")
      puts
      puts Formatter.headline("Running #{klass}##{method}", color: :magenta)
    end

    def info_header(text)
      puts Formatter.headline(text, color: :cyan)
    end

    def test(*arguments, env: {}, verbose: @verbose, expect_error: false, multistage: false)
      step = Step.new(arguments, env: env, verbose: verbose, expect_error: expect_error, multistage: multistage)
      step.run(dry_run: @dry_run, fail_fast: @fail_fast)
      @steps << step
      step
    end
  end
end
