# frozen_string_literal: true

module Homebrew
  # Wraps command invocations. Instantiated by Test#test.
  # Handles logging and pretty-printing.
  class Step
    attr_reader :command, :output

    # Instantiates a Step object.
    # @param test [Test] The parent Test object
    # @param command [Array<String>] Command to execute and arguments
    # @param options [Hash] Recognized options are:
    #   :repository
    #   :env
    def initialize(test, command, repository:, env: {})
      @test = test
      @category = test.category
      @command = command
      @status = :running
      @repository = repository
      @env = env
    end

    def command_trimmed
      @command.reject { |arg| arg.to_s.start_with?("--exclude") }
              .join(" ")
              .gsub("#{HOMEBREW_LIBRARY}/Taps/", "")
              .gsub("#{HOMEBREW_PREFIX}/", "")
    end

    def passed?
      @status == :passed
    end

    def failed?
      @status == :failed
    end

    def puts_command
      puts
      puts Formatter.headline(command_trimmed, color: :blue)
    end

    def puts_result
      puts Formatter.headline(Formatter.error("FAILED")) if failed?
    end

    def output?
      @output.present?
    end

    def run
      puts_command
      if Homebrew.args.dry_run?
        @status = :passed
        puts_result
        return
      end

      raise "git should always be called with -C!" if @command[0] == "git" && !%w[-C clone].include?(@command[1])

      executable, *args = @command

      verbose = Homebrew.args.verbose?

      result = system_command executable, args:         args,
                                          print_stdout: verbose,
                                          print_stderr: verbose,
                                          env:          @env

      @status = result.success? ? :passed : :failed
      puts_result

      output = result.merged_output

      if output.present?
        output.force_encoding(Encoding::UTF_8)

        @output = if output.valid_encoding?
          output
        else
          output.encode!(Encoding::UTF_16, invalid: :replace)
          output.encode!(Encoding::UTF_8)
        end

        puts @output if failed? && !verbose
      end

      exit 1 if Homebrew.args.fail_fast? && failed?
    end
  end
end
