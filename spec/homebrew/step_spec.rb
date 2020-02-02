# frozen_string_literal: true

require "spec_helper"

describe Homebrew::Step do
  before do
    allow(Homebrew).to receive(:args).and_return(OpenStruct.new)
  end

  let(:test) { OpenStruct.new }
  let(:command) { ["brew", "config"] }
  let(:repository) { OpenStruct.new }
  let(:step) { described_class.new(test, command, repository: repository) }

  describe "#run" do
    it "runs the command" do
      expect(step).to receive(:system_command)
        .with("brew", args: ["config"], env: {}, print_stderr: nil, print_stdout: nil)
        .and_return(OpenStruct.new(success?: true, merged_output: ""))
      step.run
    end
  end
end
