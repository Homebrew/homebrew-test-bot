# frozen_string_literal: true

require "spec_helper"

describe Homebrew::Tests::Setup do
  before do
    allow(Homebrew).to receive(:args).and_return(OpenStruct.new)
  end

  describe "#setup" do
    it "is successful" do
      expect(described_class.new.setup.passed?).to be(true)
    end
  end
end
