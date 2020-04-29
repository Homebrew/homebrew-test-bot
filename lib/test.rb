# frozen_string_literal: true

module Homebrew
  class Test
    def failed_steps
      @steps.select(&:failed?)
    end

    protected

    attr_reader :tap, :git, :steps, :repository, :test_bot_tap, :brewbot_root

    def initialize(tap: nil, git: nil, create_brewbot_root: false)
      @tap = tap || CoreTap.instance
      @git = git

      @steps = []

      @test_bot_tap = @tap.to_s == "homebrew/test-bot"
      @repository = @tap.path

      if create_brewbot_root
        @brewbot_root = Pathname.pwd + "brewbot"
        FileUtils.mkdir_p @brewbot_root
      end
    end

    def change_git!(git)
      @git = git
    end

    def test_header(klass, method: "run!")
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
