# frozen_string_literal: true

require "ostruct"
require "spec_helper"

describe Homebrew::Tests::Setup do
  before do
    allow(Homebrew).to receive(:args).and_return(OpenStruct.new)
  end

  describe "#run!" do
    it "is successful" do
      expect(described_class.new.run!(args: OpenStruct.new).passed?).to be(true)
    end
  end
end
