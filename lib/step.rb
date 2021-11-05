# frozen_string_literal: true

module Homebrew
  # Wraps command invocations. Instantiated by Test#test.
  # Handles logging and pretty-printing.
  class Step
    attr_reader :command, :name, :status, :output, :start_time, :end_time

    # Instantiates a Step object.
    # @param command [Array<String>] Command to execute and arguments.
    # @param env [Hash] Environment variables to set when running command.
    def initialize(command, env:, verbose:)
      @command = command
      @env = env
      @verbose = verbose

      @name = command[1].delete("-")
      @status = :running
      @output = nil
    end

    def command_trimmed
      command.reject { |arg| arg.to_s.start_with?("--exclude") }
             .join(" ")
             .delete_prefix("#{HOMEBREW_LIBRARY}/Taps/")
             .delete_prefix("#{HOMEBREW_PREFIX}/")
             .delete_prefix("/usr/bin/")
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

    def ignore
      @status = :ignored
    end

    def puts_command
      puts Formatter.headline(command_trimmed, color: :blue)
    end

    def puts_result
      puts Formatter.headline(Formatter.error("FAILED"), color: :red) if failed?
    end

    def output?
      @output.present?
    end

    # The execution time of the task.
    # Precondition: Step#run has been called.
    # @return [Float] execution time in seconds
    def time
      end_time - start_time
    end

    def run(dry_run: false, fail_fast: false)
      @start_time = Time.now

      puts_command
      if dry_run
        @status = :passed
        puts_result
        return
      end

      raise "git should always be called with -C!" if command[0] == "git" && %w[-C clone].exclude?(command[1])

      executable, *args = command

      result = system_command executable, args:         args,
                                          print_stdout: @verbose,
                                          print_stderr: @verbose,
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

        if @verbose
          puts
        elsif failed?
          puts @output
          puts
        end
      end

      exit 1 if fail_fast && failed?
    end
  end
end
