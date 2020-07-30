# frozen_string_literal: true

module Homebrew
  module Tests
    class CleanupBefore < TestCleanup
      def run!(args:)
        test_header(:CleanupBefore)

        if tap.to_s != CoreTap.instance.name
          core_path = CoreTap.instance.path
          if core_path.exist?
            test git, "-C", core_path.to_s, "fetch", "--depth=1", "origin", args: args
            reset_if_needed(core_path.to_s, args: args)
          else
            test git, "clone", "--depth=1",
                  CoreTap.instance.default_remote,
                  core_path.to_s,
                  args: args
          end
        end

        Pathname.glob("*.bottle*.*").each(&:unlink)

        # Keep all "brew" invocations after cleanup_shared
        # (which cleans up Homebrew/brew)
        cleanup_shared(args: args)

        installed_taps = Tap.select(&:installed?).map(&:name)
        (REQUIRED_TAPS - installed_taps).each do |tap|
          test "brew", "tap", tap, args: args
        end

        # install newer Git when needed
        if OS.mac? && MacOS.version < :sierra
          test "brew", "install", "git", args: args
          ENV["HOMEBREW_FORCE_BREWED_GIT"] = "1"
          change_git!("#{HOMEBREW_PREFIX}/opt/git/bin/git")
        end

        brew_version = Utils.safe_popen_read(
          git, "-C", HOMEBREW_REPOSITORY.to_s,
                "describe", "--tags", "--abbrev", "--dirty"
        ).strip
        brew_commit_subject = Utils.safe_popen_read(
          git, "-C", HOMEBREW_REPOSITORY.to_s,
                "log", "-1", "--format=%s"
        ).strip
        puts
        verb = tap ? "Using" : "Testing"
        puts Formatter.headline("#{verb} Homebrew/brew #{brew_version} (#{brew_commit_subject})", color: :cyan)
      end
    end
  end
end
