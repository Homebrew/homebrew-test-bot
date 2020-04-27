# frozen_string_literal: true

require "spec_helper"

describe Homebrew::Test do
  before do
    allow(Homebrew).to receive(:args).and_return(OpenStruct.new)
  end

  let(:argument) { "HEAD" }
  let(:tap) { CoreTap.instance }
  let(:git) { "git" }
  let(:skip_setup) { false }
  let(:skip_cleanup_before) { false }
  let(:skip_cleanup_after) { false }
  let(:test) do
    described_class.new(argument,
      tap:                 tap,
      git:                 git,
      skip_setup:          skip_setup,
      skip_cleanup_before: skip_cleanup_before,
      skip_cleanup_after:  skip_cleanup_after)
  end

  describe "#setup" do
    it "is successful" do
      expect(test.setup.passed?).to be(true)
    end
  end
end
