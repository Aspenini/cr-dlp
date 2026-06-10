module CrDlp
  record ProcessResult,
    exit_code : Int32,
    output : String,
    error : String do
    def success? : Bool
      exit_code == 0
    end
  end

  abstract class ProcessRunner
    abstract def run(command : String, arguments : Array(String)) : ProcessResult

    def run_shell(command : String) : ProcessResult
      raise PostProcessingError.new("Process runner does not support shell commands")
    end

    def run_with_input(
      command : String,
      arguments : Array(String),
      &writer : IO ->
    ) : ProcessResult
      raise PostProcessingError.new("Process runner does not support streamed input")
    end

    def executable_available?(command : String) : Bool
      true
    end
  end

  class SystemProcessRunner < ProcessRunner
    def executable_available?(command : String) : Bool
      File.exists?(command) || !Process.find_executable(command).nil?
    end

    def run(command : String, arguments : Array(String)) : ProcessResult
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run(command, arguments, output: output, error: error)
      ProcessResult.new(status.exit_code? || 1, output.to_s, error.to_s)
    rescue exception : IO::Error
      raise PostProcessingError.new(
        "Unable to execute #{command}: #{exception.message}",
        cause: exception,
      )
    end

    def run_shell(command : String) : ProcessResult
      {% if flag?(:win32) %}
        run(ENV["COMSPEC"]? || "cmd.exe", ["/D", "/S", "/C", command])
      {% else %}
        run("/bin/sh", ["-c", command])
      {% end %}
    end

    def run_with_input(
      command : String,
      arguments : Array(String),
      &writer : IO ->
    ) : ProcessResult
      output = IO::Memory.new
      error = IO::Memory.new
      process = Process.new(
        command,
        arguments,
        input: Process::Redirect::Pipe,
        output: output,
        error: error,
      )
      begin
        writer.call(process.input)
        process.input.close
        status = process.wait
        ProcessResult.new(status.exit_code? || 1, output.to_s, error.to_s)
      rescue exception
        process.input.close rescue nil
        process.terminate rescue nil
        process.wait rescue nil
        raise exception
      end
    rescue exception : IO::Error
      raise PostProcessingError.new(
        "Unable to execute #{command}: #{exception.message}",
        cause: exception,
      )
    end
  end
end
