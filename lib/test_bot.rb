# frozen_string_literal: true

require_relative "step"
require_relative "test_ci_upload"
require_relative "test_runner"

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
        Tap.fetch(url_path) if url_path.match?(HOMEBREW_TAP_REGEX)
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

      if Homebrew.args.local?
        ENV["HOMEBREW_HOME"] = ENV["HOME"] = "#{Dir.pwd}/home"
        ENV["HOMEBREW_LOGS"] = "#{Dir.pwd}/logs"
        FileUtils.mkdir_p ENV["HOMEBREW_HOME"]
        FileUtils.mkdir_p ENV["HOMEBREW_LOGS"]
      end

      test_bot_revision = Utils.popen_read(
        GIT, "-C", Tap.fetch("homebrew/test-bot").path.to_s,
             "log", "-1", "--format=%h (%s)"
      ).strip
      puts Formatter.headline("Using Homebrew/homebrew-test-bot #{test_bot_revision}", color: :cyan)

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

      return TestCiUpload.run!(tap) if Homebrew.args.ci_upload?

      Homebrew.failed = !TestRunner.run!(tap, git: GIT)
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
    end
  end
end
