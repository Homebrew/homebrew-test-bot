# frozen_string_literal: true

require "spec_helper"

describe Homebrew::Step do
  let(:command) { ["brew", "config"] }
  let(:env) { {} }
  let(:verbose) { false }
  let(:step) { described_class.new(command, env:, verbose:) }

  describe "#run" do
    it "runs the command" do
      expect(step).to receive(:system_command)
        .with("brew", args: ["config"], env:, print_stderr: verbose, print_stdout: verbose)
        .and_return(OpenStruct.new(success?: true, merged_output: ""))
      step.run
    end
  end
end
