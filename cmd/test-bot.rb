# frozen_string_literal: true

require "cli/parser"
module Homebrew
  module_function

  def test_bot_args
    Homebrew::CLI::Parser.new do
      usage_banner <<~EOS
        `test-bot` [<options>] <URL>|<formula>:

        Test the full lifecycle of a formula change.
      EOS

      switch "--dry-run",
             description: "print what would be done rather than doing it."
      switch "--cleanup",
             description: "clean all state from the Homebrew directory. Use with care!"
      switch "--skip-setup",
             description: "don't check if the local system is set up correctly."
      switch "--keep-old",
             description: "run `brew bottle --keep-old` to build new bottles for a single platform."
      switch "--skip-relocation",
             description: "run `brew bottle --skip-relocation` to build new bottles that don't require relocation."
      switch "--local",
             description: "ask Homebrew to write verbose logs under `./logs/` and set `$HOME` to `./home/`"
      flag   "--tap=",
             description: "use the `git` repository of the given tap."
      switch "--fail-fast",
             description: "immediately exit on a failing step."
      switch :verbose,
             description: "print test step output in real time. Has the side effect of " \
                          "passing output as raw bytes instead of re-encoding in UTF-8."
      switch "--no-pull",
             description: "don't use `brew pull` to download URLs or `git checkout` to " \
                          "checkout hashes. This assumes your CI system has already put you " \
                          "on the correct revision to test."
      switch "--test-default-formula",
             description: "use a default testing formula when not building a tap and no other formulae are specified."
      flag   "--bintray-org=",
             description: "upload to the given Bintray organisation."
      flag   "--root-url=",
             description: "use the specified <URL> as the root of the bottle's URL instead of Homebrew's default."
      flag   "--git-name=",
             description: "set the Git author/committer names to the given name."
      flag   "--git-email=",
             description: "set the Git author/committer email to the given email."
      switch "--ci-upload",
             description: "use the Homebrew CI bottle upload options."
      switch "--publish",
             description: "publish the uploaded bottles."
      switch "--skip-recursive-dependents",
             description: "only test the direct dependents."
    end
  end

  def test_bot
    setup_argv_and_env

    test_bot_args.parse

    # Keep this after the .parse to keep --help fast.
    require_relative "../lib/test_bot"

    Homebrew::TestBot.run!
  end

  def setup_argv_and_env
    github_actions = ENV["GITHUB_ACTIONS"].present?
    if github_actions
      ARGV << "--verbose" << "--no-pull" << "--cleanup"
      ENV["HOMEBREW_COLOR"] = "1"
      ENV["HOMEBREW_GITHUB_ACTIONS"] = "1"
    end

    if ENV["GITHUB_ACTIONS_HOMEBREW_SELF_HOSTED"].present?
      ARGV << "--local"
    elsif github_actions
      ARGV << "--test-default-formula"
    end

    ARGV << "--verbose" if ARGV.include?("--ci-upload")
  end
end
