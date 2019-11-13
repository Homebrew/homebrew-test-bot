# frozen_string_literal: true

require "spec_helper"

describe Homebrew::Test do
  before do
    allow(ARGV).to receive(:verbose?).and_return(false)
  end

  let(:argument) { "HEAD" }
  let(:test) { described_class.new(argument) }

  context "#setup" do
    it "is successful" do
      expect(test.setup.passed?).to be(true)
    end
  end
end
