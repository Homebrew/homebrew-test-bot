# frozen_string_literal: true

require "spec_helper"

describe Homebrew::Step do
  before do
    allow(Homebrew).to receive(:args).and_return(OpenStruct.new)
  end

  let(:command) { ["brew", "config"] }
  let(:env) { {} }
  let(:step) { described_class.new(command, env: env) }

  describe "#run" do
    it "runs the command" do
      expect(step).to receive(:system_command)
        .with("brew", args: ["config"], env: env, print_stderr: nil, print_stdout: nil)
        .and_return(OpenStruct.new(success?: true, merged_output: ""))
      step.run
    end
  end
end
