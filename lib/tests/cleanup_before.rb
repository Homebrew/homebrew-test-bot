# frozen_string_literal: true

module Homebrew
  module Tests
    class CleanupBefore < TestCleanup
      def run!(args:)
        test_header(:CleanupBefore)

        if tap.to_s != CoreTap.instance.name
          core_path = CoreTap.instance.path
          if core_path.exist?
            reset_if_needed(core_path.to_s)
          else
            test git, "clone",
                 CoreTap.instance.default_remote,
                 core_path.to_s
          end
        end

        Pathname.glob("*.bottle*.*").each(&:unlink)

        if ENV["HOMEBREW_GITHUB_ACTIONS"] && !ENV["GITHUB_ACTIONS_HOMEBREW_SELF_HOSTED"]
          # minimally fix brew doctor failures (a full clean takes ~5m)
          if OS.linux?
            # brew doctor complains
            node = Pathname("/usr/local/include/node/")
            test "sudo", "mv", node.to_s, "/tmp" if node.exist?
          elsif OS.mac?
            delete_or_move Pathname.glob(HOMEBREW_CELLAR/"*")
          end
        end

        # Keep all "brew" invocations after cleanup_shared
        # (which cleans up Homebrew/brew)
        cleanup_shared

        installed_taps = Tap.select(&:installed?).map(&:name)
        (REQUIRED_TAPS - installed_taps).each do |tap|
          test "brew", "tap", tap
        end
      end
    end
  end
end
