class Testbottest < Formula
  desc "Minimal C program and Makefile used for testing Homebrew"
  homepage "https://github.com/Homebrew/brew"
  url "file://#{File.expand_path(__dir__)}/tarballs/testbottest-0.1.tbz"
  sha256 "246c4839624d0b97338ce976100d56bd9331d9416e178eb0f74ef050c1dbdaad"
  head "https://github.com/Homebrew/homebrew-test-bot.git"

  bottle do
  end

  depends_on :java => ["1.0+", :optional]

  fails_with :gcc do
    build 1
    cause "testing"
  end

  def install
    odie "whoops, shouldn't be using java!" if build.with?(:java)

    system "make", "install", "PREFIX=#{prefix}"
  end

  def post_install
    system "#{bin}/testbottest"
  end

  test do
    assert_equal "testbottest\n", shell_output("#{bin}/testbottest")
  end
end
