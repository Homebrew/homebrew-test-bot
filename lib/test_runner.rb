# frozen_string_literal: true

require_relative "test"
require_relative "tests/cleanup"
require_relative "tests/formulae"
require_relative "tests/setup"
require_relative "tests/tap_syntax"

module Homebrew
  module TestRunner
    module_function

    def run!(tap, git:)
      tests = []
      skip_setup = Homebrew.args.skip_setup?
      skip_cleanup_before = false

      test_bot_args = Homebrew.args.named

      # With no arguments just build the most recent commit.
      test_bot_args << "HEAD" if test_bot_args.empty?

      test_bot_args.each do |argument|
        skip_cleanup_after = argument != test_bot_args.last
        current_tests = build_tests(argument, tap:                 tap,
                                              git:                 git,
                                              skip_setup:          skip_setup,
                                              skip_cleanup_before: skip_cleanup_before,
                                              skip_cleanup_after:  skip_cleanup_after)
        skip_setup = true
        skip_cleanup_before = true
        tests += current_tests.values
        run_tests(current_tests)
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

      failed_steps.empty?
    end

    def no_only_args?
      any_only = Homebrew.args.only_cleanup_before? ||
                 Homebrew.args.only_setup? ||
                 Homebrew.args.only_tap_syntax? ||
                 Homebrew.args.only_formulae? ||
                 Homebrew.args.only_cleanup_after?
      !any_only
    end

    def build_tests(argument, tap:, git:, skip_setup:, skip_cleanup_before:, skip_cleanup_after:)
      tests = {}

      tests[:setup] = Tests::Setup.new if !skip_setup && (no_only_args? || Homebrew.args.only_setup?)
      tests[:tap_syntax] = Tests::TapSyntax.new(tap) if no_only_args? || Homebrew.args.only_tap_syntax?

      if no_only_args? || Homebrew.args.only_formulae?
        tests[:formulae] = Tests::Formulae.new(argument, tap: tap, git: git)
      end

      if Homebrew.args.cleanup?
        if !skip_cleanup_before && (no_only_args? || Homebrew.args.only_cleanup_before?)
          tests[:cleanup_before] = Tests::Cleanup.new(tap: tap, git: git)
        end

        if !skip_cleanup_after &&  (no_only_args? || Homebrew.args.only_cleanup_after?)
          tests[:cleanup_after]  = Tests::Cleanup.new(tap: tap, git: git)
        end
      end

      tests
    end

    def run_tests(tests)
      tests[:cleanup_before]&.cleanup_before
      begin
        tests[:setup]&.setup
        tests[:tap_syntax]&.tap_syntax
        tests[:formulae]&.test_formulae
      ensure
        tests[:cleanup_after]&.cleanup_after
      end
    end
  end
end
