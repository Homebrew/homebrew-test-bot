# typed: true
# frozen_string_literal: true

module Utils
  module Analytics
    sig { params(command: String, passed: T::Boolean).void }
    def self.report_test_bot_test(command, passed); end
  end
end
