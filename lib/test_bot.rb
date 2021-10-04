# frozen_string_literal: true

require_relative "step"
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

    def resolve_test_tap(tap = nil)
      return Tap.fetch(tap) if tap

      # Get tap from GitHub Actions GITHUB_REPOSITORY
      git_url = ENV["GITHUB_REPOSITORY"]
      return if git_url.blank?

      url_path = git_url.sub(%r{^https?://.*github\.com/}, "")
                        .chomp("/")
                        .sub(/\.git$/, "")

      return CoreTap.instance if url_path == CoreTap.instance.full_name

      begin
        Tap.fetch(url_path) if url_path.match?(HOMEBREW_TAP_REGEX)
      rescue
        # Don't care if tap fetch fails
        nil
      end
    end

    def run!(args)
      $stdout.sync = true
      $stderr.sync = true

      if Pathname.pwd == HOMEBREW_PREFIX && args.cleanup?
        raise UsageError, "cannot use --cleanup from HOMEBREW_PREFIX as it will delete all output."
      end

      ENV["HOMEBREW_BOOTSNAP"] = "1"
      ENV["HOMEBREW_DEVELOPER"] = "1"
      ENV["HOMEBREW_NO_AUTO_UPDATE"] = "1"
      ENV["HOMEBREW_NO_EMOJI"] = "1"
      ENV["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] = "1"
      ENV["HOMEBREW_FAIL_LOG_LINES"] = "150"
      ENV["HOMEBREW_CURL_PATH"] = "/usr/bin/curl"
      ENV["HOMEBREW_GIT_PATH"] = GIT
      ENV["HOMEBREW_PATH"] = ENV["PATH"] =
        "#{HOMEBREW_PREFIX}/bin:#{HOMEBREW_PREFIX}/sbin:#{ENV["PATH"]}"

      if args.local?
        ENV["HOMEBREW_HOME"] = ENV["HOME"] = "#{Dir.pwd}/home"
        ENV["HOMEBREW_LOGS"] = "#{Dir.pwd}/logs"
        FileUtils.mkdir_p ENV["HOMEBREW_HOME"]
        FileUtils.mkdir_p ENV["HOMEBREW_LOGS"]
      end

      tap = resolve_test_tap(args.tap)
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

      test_bot_tap = Tap.fetch("homebrew/test-bot")

      if test_bot_tap != tap
        test_bot_revision = Utils.safe_popen_read(
          GIT, "-C", test_bot_tap.path.to_s,
          "log", "-1", "--format=%h (%s)"
        ).strip
        puts Formatter.headline("Using Homebrew/homebrew-test-bot #{test_bot_revision}", color: :cyan)
      end

      brew_version = Utils.safe_popen_read(
        GIT, "-C", HOMEBREW_REPOSITORY.to_s,
        "describe", "--tags", "--abbrev", "--dirty"
      ).strip
      brew_commit_subject = Utils.safe_popen_read(
        GIT, "-C", HOMEBREW_REPOSITORY.to_s,
        "log", "-1", "--format=%s"
      ).strip
      puts Formatter.headline("Using Homebrew/brew #{brew_version} (#{brew_commit_subject})", color: :cyan)

      if tap.to_s != CoreTap.instance.name
        core_revision = Utils.safe_popen_read(
          GIT, "-C", CoreTap.instance.path.to_s,
          "log", "-1", "--format=%h (%s)"
        ).strip
        puts Formatter.headline("Using #{CoreTap.instance.full_name} #{core_revision}", color: :cyan)
      end

      if tap
        tap_github = " (#{ENV["GITHUB_REPOSITORY"]}" if tap.full_name != ENV["GITHUB_REPOSITORY"]
        tap_revision = Utils.safe_popen_read(
          GIT, "-C", tap.path.to_s,
          "log", "-1", "--format=%h (%s)"
        ).strip
        puts Formatter.headline("Testing #{tap.full_name}#{tap_github} #{tap_revision}:", color: :cyan)
      end

      ENV["HOMEBREW_GIT_NAME"] = args.git_name || "BrewTestBot"
      ENV["HOMEBREW_GIT_EMAIL"] = args.git_email ||
                                  "1589480+BrewTestBot@users.noreply.github.com"

      Homebrew.failed = !TestRunner.run!(tap, git: GIT, args: args)
    ensure
      if HOMEBREW_CACHE.exist?
        Dir.glob("*.bottle*.tar.gz") do |bottle_file|
          FileUtils.rm_f HOMEBREW_CACHE/bottle_file
        end
      end
    end
  end
end
