# frozen_string_literal: true

require "simplecov"
SimpleCov.start do
  add_filter "/vendor/"
  minimum_coverage 10
end

# Setup Sorbet for usage in stubs.
require "sorbet-runtime"
class Module
  include T::Sig
end

PROJECT_ROOT = Pathname(__dir__).parent.freeze
STUB_PATH = (PROJECT_ROOT/"spec/stub").freeze
$LOAD_PATH.unshift(STUB_PATH)

Dir.glob("#{PROJECT_ROOT}/lib/**/*.rb").each do |file|
  require file
end

require "global"
require "active_support/core_ext/object/blank"

SimpleCov.formatters = [SimpleCov::Formatter::HTMLFormatter]

require "bundler"
require "rspec/support/object_formatter"

RSpec.configure do |config|
  config.filter_run_when_matching :focus
  config.expect_with :rspec do |c|
    c.max_formatted_output_length = 200
  end

  # Never truncate output objects.
  RSpec::Support::ObjectFormatter.default_instance.max_formatted_output_length = nil

  config.around do |example|
    Bundler.with_original_env { example.run }
  end
end
