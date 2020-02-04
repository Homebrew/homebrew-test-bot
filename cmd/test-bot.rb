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
      switch "--keep-logs",
             description: "write and keep log files under `./brewbot/`."
      switch "--cleanup",
             description: "clean all state from the Homebrew directory. Use with care!"
      switch "--skip-setup",
             description: "don't check if the local system is set up correctly."
      switch "--junit",
             description: "generate a JUnit XML test results file."
      switch "--no-bottle",
             description: "run `brew install` without `--build-bottle`."
      switch "--keep-old",
             description: "run `brew bottle --keep-old` to build new bottles for a single platform."
      switch "--skip-relocation",
             description: "run `brew bottle --skip-relocation` to build new bottles that don't require relocation."
      switch "--HEAD",
             description: "run `brew install` with `--HEAD`."
      switch "--local",
             description: "ask Homebrew to write verbose logs under `./logs/` and set `$HOME` to `./home/`"
      flag   "--tap=",
             description: "use the `git` repository of the given tap."
      switch "--fail-fast",
             description: "immediately exit on a failing step."
      switch :verbose,
             description: "print test step output in real time. Has the side effect of " \
                          "passing output as raw bytes instead of re-encoding in UTF-8."
      switch "--fast",
             description: "don't install any packages, but run e.g. `brew audit` anyway."
      switch "--keep-tmp",
             description: "keep temporary files written by main installs and tests that are run."
      switch "--no-pull",
             description: "don't use `brew pull` when possible."
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
      switch "--ci-pr",
             description: "use the Homebrew pull request CI options. Implies `--cleanup`: use with care!"
      switch "--ci-testing",
             description: "use the Homebrew testing CI options. Implies `--cleanup`: use with care!"
      switch "--ci-auto",
             description: "automatically pick one of the Homebrew CI options based on the environment. Implies `--cleanup`: use with care!"
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
    jenkins = !ENV["JENKINS_HOME"].nil?

    github_actions = !ENV["GITHUB_ACTIONS"].nil?
    if github_actions
      ARGV << "--verbose" << "--ci-auto" << "--no-pull"
      ENV["HOMEBREW_COLOR"] = "1"
      ENV["HOMEBREW_GITHUB_ACTIONS"] = "1"
    end

    jenkins_pr = !ENV["ghprbPullLink"].nil?
    jenkins_pr ||= !ENV["ROOT_BUILD_CAUSE_GHPRBCAUSE"].nil?
    github_actions_pr = ENV["GITHUB_EVENT_NAME"] == "pull_request"

    if ARGV.include?("--ci-auto")
      if jenkins_pr ||  github_actions_pr
        ARGV << "--ci-pr"
      else
        ARGV << "--ci-testing"
      end
    end

    if ARGV.include?("--ci-pr") ||
       ARGV.include?("--ci-testing")
      ARGV << "--cleanup"
      ARGV << "--test-default-formula"
      ARGV << "--local" if jenkins
      ARGV << "--junit" if jenkins 
    end

    ARGV << "--verbose" if ARGV.include?("--ci-upload")

    return unless ARGV.include?("--local")

    ENV["HOMEBREW_HOME"] = ENV["HOME"] = "#{Dir.pwd}/home"
    FileUtils.mkdir_p ENV["HOMEBREW_HOME"]
    ENV["HOMEBREW_LOGS"] = "#{Dir.pwd}/logs"
  end
end
