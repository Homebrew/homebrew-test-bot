# frozen_string_literal: true

module Homebrew
  module TestRunner
    module_function

    def run!(tap, git:)
      tests = []
      any_errors = false
      skip_setup = Homebrew.args.skip_setup?
      skip_cleanup_before = false

      test_bot_args = Homebrew.args.named

      # With no arguments just build the most recent commit.
      test_bot_args << "HEAD" if test_bot_args.empty?

      test_bot_args.each do |argument|
        skip_cleanup_after = argument != test_bot_args.last
        current_test =
          Test.new(argument, tap:                 tap,
                             git:                 git,
                             skip_setup:          skip_setup,
                             skip_cleanup_before: skip_cleanup_before,
                             skip_cleanup_after:  skip_cleanup_after)
        skip_setup = true
        skip_cleanup_before = true
        tests << current_test
        any_errors ||= !current_test.run
      end

      failed_steps = tests.map { |test| test.steps.select(&:failed?) }
                          .flatten
                          .compact
      steps_output = if failed_steps.empty?
        "All steps passed!"
      else
        failed_steps_output = ["Error: #{failed_steps.length} failed steps!"]
        failed_steps_output += failed_steps.map(&:command_trimmed)
        failed_steps_output.join("\n")
      end
      puts steps_output

      steps_output_path = Pathname("steps_output.txt")
      steps_output_path.unlink if steps_output_path.exist?
      steps_output_path.write(steps_output)

      !any_errors
    end
  end
end
