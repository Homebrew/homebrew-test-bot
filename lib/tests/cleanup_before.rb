# frozen_string_literal: true

module Homebrew
  module Tests
    class CleanupBefore < TestCleanup
      def run!(args:)
        test_header(:CleanupBefore)

        if tap.to_s != CoreTap.instance.name
          core_path = CoreTap.instance.path
          if core_path.exist?
            test git, "-C", core_path.to_s, "fetch", "--depth=1", "origin"
            reset_if_needed(core_path.to_s)
          else
            test git, "clone", "--depth=1",
                 CoreTap.instance.default_remote,
                 core_path.to_s
          end
        end

        Pathname.glob("*.bottle*.*").each(&:unlink)

        if ENV["HOMEBREW_GITHUB_ACTIONS"] && !ENV["GITHUB_ACTIONS_HOMEBREW_SELF_HOSTED"]
          # minimally fix brew doctor failures (a full clean takes ~5m)
          if OS.linux?
            # brew doctor complains
            test "sudo", "rm", "-rf", "/usr/local/include/node/"
          elsif OS.mac?
            if Dir.glob("#{HOMEBREW_CELLAR}/*").present?
              FileUtils.mkdir_p "/tmp/test-bot-cleanup"
              # moving is much faster than deleting.
              test "bash", "-c", "mv #{HOMEBREW_CELLAR}/* /tmp/test-bot-cleanup"
            end
          end
        end

        # Keep all "brew" invocations after cleanup_shared
        # (which cleans up Homebrew/brew)
        cleanup_shared

        installed_taps = Tap.select(&:installed?).map(&:name)
        (REQUIRED_TAPS - installed_taps).each do |tap|
          test "brew", "tap", tap
        end

        # install newer Git when needed
        return unless OS.mac? && MacOS.version < :sierra

        test "brew", "install", "git"
        ENV["HOMEBREW_FORCE_BREWED_GIT"] = "1"
        change_git!("#{HOMEBREW_PREFIX}/opt/git/bin/git")
      end
    end
  end
end
