# frozen_string_literal: true

HOMEBREW_REPOSITORY = Pathname.new("/usr/local/Homebrew").freeze
HOMEBREW_PULL_OR_COMMIT_URL_REGEX = /.+/
HOMEBREW_LIBRARY = (HOMEBREW_REPOSITORY/"Library").freeze
HOMEBREW_PREFIX = Pathname.new("/usr/local").freeze
