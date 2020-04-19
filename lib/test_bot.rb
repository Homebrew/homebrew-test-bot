# frozen_string_literal: true

require_relative "step"
require_relative "test"

require "date"
require "json"

require "development_tools"
require "formula"
require "formula_installer"
require "os"
require "tap"
require "utils"
require "utils/bottles"

module Homebrew
  module TestBot
    module_function

    GIT = "/usr/bin/git"

    BYTES_IN_1_MEGABYTE = 1024*1024
    MAX_STEP_OUTPUT_SIZE = BYTES_IN_1_MEGABYTE - (200*1024) # margin of safety

    HOMEBREW_TAP_REGEX = %r{^([\w-]+)/homebrew-([\w-]+)$}.freeze

    def resolve_test_tap
      if (tap = Homebrew.args.tap)
        return Tap.fetch(tap)
      end

      return Tap.fetch(tap) if HOMEBREW_TAP_REGEX.match?(tap)

      # Get tap from GitHub Actions GITHUB_REPOSITORY
      git_url = ENV["GITHUB_REPOSITORY"]
      return if git_url.blank?

      url_path = git_url.sub(%r{^https?://.*github\.com/}, "")
                        .chomp("/")
                        .sub(/\.git$/, "")
      begin
        return Tap.fetch(url_path) if url_path.match?(HOMEBREW_TAP_REGEX)
      rescue
        # Don't care if tap fetch fails
        nil
      end
    end

    def run!
      $stdout.sync = true
      $stderr.sync = true

      if Pathname.pwd == HOMEBREW_PREFIX && Homebrew.args.cleanup?
        odie "cannot use --cleanup from HOMEBREW_PREFIX as it will delete all output."
      end

      ENV["HOMEBREW_DEVELOPER"] = "1"
      ENV["HOMEBREW_NO_AUTO_UPDATE"] = "1"
      ENV["HOMEBREW_NO_EMOJI"] = "1"
      ENV["HOMEBREW_FAIL_LOG_LINES"] = "150"
      ENV["HOMEBREW_PATH"] = ENV["PATH"] =
        "#{HOMEBREW_PREFIX}/bin:#{HOMEBREW_PREFIX}/sbin:#{ENV["PATH"]}"

      test_bot_revision = Utils.popen_read(
        GIT, "-C", Tap.fetch("homebrew/test-bot").path.to_s,
             "log", "-1", "--format=%h (%s)"
      ).strip
      puts "Homebrew/homebrew-test-bot #{test_bot_revision}"

      tap = resolve_test_tap
      # Tap repository if required, this is done before everything else
      # because Formula parsing and/or git commit hash lookup depends on it.
      # At the same time, make sure Tap is not a shallow clone.
      # bottle rebuild and bottle upload rely on full clone.
      if tap
        if !tap.path.exist?
          safe_system "brew", "tap", tap.name, "--full"
        elsif (tap.path/".git/shallow").exist?
          raise unless quiet_system GIT, "-C", tap.path, "fetch", "--unshallow"
        end
      end

      ENV["HOMEBREW_GIT_NAME"] = Homebrew.args.git_name || "BrewTestBot"
      ENV["HOMEBREW_GIT_EMAIL"] = Homebrew.args.git_email ||
                                  "homebrew-test-bot@lists.sfconservancy.org"

      tests = []
      any_errors = false
      skip_setup = Homebrew.args.skip_setup?
      skip_cleanup_before = false
      if Homebrew.args.named.empty?
        # With no arguments just build the most recent commit.
        current_test = Test.new("HEAD", tap:                 tap,
                                        git:                 GIT,
                                        skip_setup:          skip_setup,
                                        skip_cleanup_before: skip_cleanup_before)
        any_errors = !current_test.run
        tests << current_test
      else
        Homebrew.args.named.each do |argument|
          skip_cleanup_after = argument != Homebrew.args.named.last
          test_error = false
          begin
            current_test =
              Test.new(argument, tap:                 tap,
                                 git:                 GIT,
                                 skip_setup:          skip_setup,
                                 skip_cleanup_before: skip_cleanup_before,
                                 skip_cleanup_after:  skip_cleanup_after)
            skip_setup = true
            skip_cleanup_before = true
          rescue ArgumentError => e
            test_error = true
            ofail e.message
          else
            test_error = !current_test.run
            tests << current_test
          end
          any_errors ||= test_error
        end
      end
    ensure
      if HOMEBREW_CACHE.exist?
        if Homebrew.args.clean_cache?
          HOMEBREW_CACHE.children.each(&:rmtree)
        else
          Dir.glob("*.bottle*.tar.gz") do |bottle_file|
            FileUtils.rm_f HOMEBREW_CACHE/bottle_file
          end
        end
      end

      Homebrew.failed = any_errors
    end
  end
end
