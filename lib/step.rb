# frozen_string_literal: true

module Homebrew
  # Wraps command invocations. Instantiated by Test#test.
  # Handles logging and pretty-printing.
  class Step
    attr_reader :command, :name, :status, :output, :start_time, :end_time

    # Instantiates a Step object.
    # @param test [Test] The parent Test object
    # @param command [Array<String>] Command to execute and arguments
    # @param options [Hash] Recognized options are:
    #   :repository
    #   :env
    #   :puts_output_on_success
    def initialize(test, command, repository:, env: {}, puts_output_on_success: false)
      @test = test
      @category = test.category
      @command = command
      @puts_output_on_success = puts_output_on_success
      @name = command[1].delete("-")
      @status = :running
      @repository = repository
      @env = env
    end

    def log_file_path
      file = "#{@category}.#{@name}.txt"
      root = @test.log_root
      return file unless root

      root + file
    end

    def command_trimmed
      @command.reject { |arg| arg.to_s.start_with?("--exclude") }
              .join(" ")
              .gsub("#{HOMEBREW_LIBRARY}/Taps/", "")
              .gsub("#{HOMEBREW_PREFIX}/", "")
    end

    def command_short
      (@command - %W[
        brew
        -C
        #{HOMEBREW_PREFIX}
        #{HOMEBREW_REPOSITORY}
        #{@repository}
        #{Dir.pwd}
        --force
        --retry
        --verbose
        --json
      ].freeze).join(" ")
        .gsub(HOMEBREW_PREFIX.to_s, "")
        .gsub(HOMEBREW_REPOSITORY.to_s, "")
        .gsub(@repository.to_s, "")
        .gsub(Dir.pwd, "")
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
      @output && !@output.empty?
    end

    # The execution time of the task.
    # Precondition: Step#run has been called.
    # @return [Float] execution time in seconds
    def time
      end_time - start_time
    end

    def run
      @start_time = Time.now

      puts_command
      if ARGV.include? "--dry-run"
        @end_time = Time.now
        @status = :passed
        puts_result
        return
      end

      if @command[0] == "git" && !%w[-C clone].include?(@command[1])
        raise "git should always be called with -C!"
      end

      executable, *args = @command

      verbose = ARGV.verbose?

      result = system_command executable, args:         args,
                                          print_stdout: verbose,
                                          print_stderr: verbose,
                                          env:          @env

      @end_time = Time.now
      @status = result.success? ? :passed : :failed
      puts_result

      output = result.merged_output

      unless output.empty?
        output.force_encoding(Encoding::UTF_8)

        @output = if output.valid_encoding?
          output
        else
          output.encode!(Encoding::UTF_16, invalid: :replace)
          output.encode!(Encoding::UTF_8)
        end

        puts @output if (failed? || @puts_output_on_success) && !verbose
        File.write(log_file_path, @output) if ARGV.include? "--keep-logs"
      end

      exit 1 if ARGV.include?("--fail-fast") && failed?
    end
  end
end
