# frozen_string_literal: true

module Homebrew
  # Wraps command invocations. Instantiated by Test#test.
  # Handles logging and pretty-printing.
  class Step
    attr_reader :command, :name, :status, :output, :start_time, :end_time

    # Instantiates a Step object.
    # @param command [Array<String>] Command to execute and arguments.
    # @param env [Hash] Environment variables to set when running command.
    def initialize(command, env:, verbose:, expect_error:, multistage:)
      @command = command
      @env = env
      @verbose = verbose
      @expect_error = expect_error
      @multistage = multistage

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

    def produced_error?
      (@expect_error && passed?) || (!@expect_error && failed?)
    end

    def produced_no_error_unexpectedly?
      @expect_error && failed?
    end

    def errors_to_report?
      !@output.empty? && produced_error?
    end

    def pending_pass?
      @status == :pending_pass
    end

    def pending_fail?
      @status == :pending_fail
    end

    def pending?
      pending_pass? || pending_fail?
    end

    def resolved_status_from_pending_status
      return @status unless pending?

      if pending_pass?
        :passed
      else
        :failed
      end
    end

    def resolve_pending(passed: nil)
      return unless pending?

      @status = if passed.nil?
        resolved_status_from_pending_status
      elsif passed
        :passed
      else
        :failed
      end

      # This is the second time we're showing this, but didn't
      # actually run the command this time, so show a visual cue.
      puts_command(:orange)
      puts_result

      return unless errors_to_report?

      puts @output
      puts
    end

    def puts_command(color)
      puts Formatter.headline(command_trimmed, color: color)
    end

    def puts_result
      message = produced_no_error_unexpectedly? ? "Expected to error, but did not" : "FAILED"
      puts Formatter.headline(Formatter.error(message), color: :red) if failed? || produced_error?
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

      puts_command(:blue)
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
      succeeded = @expect_error ? !result.success? : result.success?
      passed_status = @multistage ? :pending_pass : :passed
      failed_status = @multistage ? :pending_fail : :failed
      @status = succeeded ? passed_status : failed_status
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
