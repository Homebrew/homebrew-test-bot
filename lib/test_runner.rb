# frozen_string_literal: true

require_relative "test"
require_relative "test_cleanup"
require_relative "tests/cleanup_after"
require_relative "tests/cleanup_before"
require_relative "tests/formulae"
require_relative "tests/setup"
require_relative "tests/tap_syntax"

module Homebrew
  module TestRunner
    module_function

    def run!(tap, git:, args:)
      tests = []
      skip_setup = args.skip_setup?
      skip_cleanup_before = false

      test_bot_args = args.named.dup

      # With no arguments just build the most recent commit.
      test_bot_args << "HEAD" if test_bot_args.empty?

      test_bot_args.each do |argument|
        skip_cleanup_after = argument != test_bot_args.last
        current_tests = build_tests(argument, tap:                 tap,
                                              git:                 git,
                                              skip_setup:          skip_setup,
                                              skip_cleanup_before: skip_cleanup_before,
                                              skip_cleanup_after:  skip_cleanup_after,
                                              args:                args)
        skip_setup = true
        skip_cleanup_before = true
        tests += current_tests.values
        run_tests(current_tests, args: args)
      end

      failed_steps = tests.map(&:failed_steps)
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

    def no_only_args?(args)
      any_only = args.only_cleanup_before? ||
                 args.only_setup? ||
                 args.only_tap_syntax? ||
                 args.only_formulae? ||
                 args.only_cleanup_after?
      !any_only
    end

    def build_tests(argument, tap:, git:, skip_setup:, skip_cleanup_before:, skip_cleanup_after:, args:)
      tests = {}

      no_only_args = no_only_args?(args)

      if !skip_setup && (no_only_args || args.only_setup?)
        tests[:setup] = Tests::Setup.new(dry_run:   args.dry_run?,
                                         fail_fast: args.fail_fast?,
                                         verbose:   args.verbose?)
      end

      if no_only_args || args.only_tap_syntax?
        tests[:tap_syntax] = Tests::TapSyntax.new(tap:       tap || CoreTap.instance,
                                                  dry_run:   args.dry_run?,
                                                  fail_fast: args.fail_fast?,
                                                  verbose:   args.verbose?)
      end

      if no_only_args || args.only_formulae?
        tests[:formulae] = Tests::Formulae.new(argument, tap:       tap,
                                                         git:       git,
                                                         dry_run:   args.dry_run?,
                                                         fail_fast: args.fail_fast?,
                                                         verbose:   args.verbose?)
      end

      if args.cleanup?
        if !skip_cleanup_before && (no_only_args || args.only_cleanup_before?)
          tests[:cleanup_before] = Tests::CleanupBefore.new(tap:       tap,
                                                            git:       git,
                                                            dry_run:   args.dry_run?,
                                                            fail_fast: args.fail_fast?,
                                                            verbose:   args.verbose?)
        end

        if !skip_cleanup_after && (no_only_args || args.only_cleanup_after?)
          tests[:cleanup_after] = Tests::CleanupAfter.new(tap:       tap,
                                                          git:       git,
                                                          dry_run:   args.dry_run?,
                                                          fail_fast: args.fail_fast?,
                                                          verbose:   args.verbose?)
        end
      end

      tests
    end

    def run_tests(tests, args:)
      tests[:cleanup_before]&.run!(args: args)
      begin
        tests[:setup]&.run!(args: args)
        tests[:tap_syntax]&.run!(args: args)
        tests[:formulae]&.run!(args: args)
      ensure
        tests[:cleanup_after]&.run!(args: args)
      end
    end
  end
end
