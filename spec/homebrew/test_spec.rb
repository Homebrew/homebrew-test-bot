# frozen_string_literal: true

require "spec_helper"

describe Homebrew::Test do
  before do
    allow(Homebrew).to receive(:args).and_return(OpenStruct.new)
  end

  let(:argument) { "HEAD" }
  let(:test) { described_class.new(argument) }

  describe "#setup" do
    it "is successful" do
      expect(test.setup.passed?).to be(true)
    end
  end
end
