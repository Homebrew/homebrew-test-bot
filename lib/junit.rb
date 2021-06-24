# frozen_string_literal: true

require "rexml/document"
require "rexml/xmldecl"
require "rexml/cdata"

module Homebrew
  class Junit
    BYTES_IN_1_MEGABYTE = 1024*1024
    MAX_STEP_OUTPUT_SIZE = (BYTES_IN_1_MEGABYTE - (200*1024)).freeze # margin of safety

    def initialize(tests)
      @tests = tests
    end

    def build(filters: nil)
      filters ||= []

      @xml_document = REXML::Document.new
      @xml_document << REXML::XMLDecl.new
      testsuites = @xml_document.add_element "testsuites"

      @tests.each do |test|
        testsuite = testsuites.add_element "testsuite"
        testsuite.add_attribute "name", "brew-test-bot.#{Utils::Bottles.tag}"
        testsuite.add_attribute "tests", test.steps.count(&:passed?)
        testsuite.add_attribute "failures", test.steps.count(&:failed?)
        testsuite.add_attribute "timestamp", test.steps.first.start_time.iso8601

        test.steps.each do |step|
          next unless filters.any? { |filter| step.command_short.start_with? filter }

          testcase = testsuite.add_element "testcase"
          testcase.add_attribute "name", step.command_short
          testcase.add_attribute "status", step.status
          testcase.add_attribute "time", step.time
          testcase.add_attribute "timestamp", step.start_time.iso8601

          next unless step.output?

          output = sanitize_output_for_xml(step.output)
          cdata = REXML::CData.new output

          if step.passed?
            elem = testcase.add_element "system-out"
          else
            elem = testcase.add_element "failure"
            elem.add_attribute "message",
                               "#{step.status}: #{step.command.join(" ")}"
          end

          elem << cdata
        end
      end
    end

    def write(filename)
      output_path = Pathname(filename)
      output_path.unlink if output_path.exist?
      output_path.open("w") do |xml_file|
        pretty_print_indent = 2
        @xml_document.write(xml_file, pretty_print_indent)
      end
    end

    private

    def sanitize_output_for_xml(output)
      return output if output.blank?

      # Remove invalid XML CData characters from step output.
      invalid_xml_pat =
        /[^\x09\x0A\x0D\x20-\uD7FF\uE000-\uFFFD\u{10000}-\u{10FFFF}]/
      output.gsub!(invalid_xml_pat, "\uFFFD")

      return output if output.bytesize <= MAX_STEP_OUTPUT_SIZE

      # Truncate to 1MB to avoid hitting CI limits
      output =
        truncate_text_to_approximate_size(
          output, MAX_STEP_OUTPUT_SIZE, front_weight: 0.0
        )
      "truncated output to 1MB:\n#{output}"
    end
  end
end
