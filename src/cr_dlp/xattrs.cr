module CrDlp
  enum XAttrFailureReason
    NoSpace
    ValueTooLong
    Unsupported
    Other
  end

  class XAttrWriteError < Error
    getter reason : XAttrFailureReason

    def initialize(message : String, @reason = XAttrFailureReason::Other, cause : Exception? = nil)
      super(message, cause)
    end
  end

  abstract class XAttrWriter
    abstract def write(path : String, key : String, value : String)
  end

  class SystemXAttrWriter < XAttrWriter
    def initialize(@process_runner : ProcessRunner)
    end

    def write(path : String, key : String, value : String)
      {% if flag?(:win32) %}
        if key.includes?(':')
          raise XAttrWriteError.new(
            "NTFS alternate data stream names cannot contain ':'",
            XAttrFailureReason::Unsupported,
          )
        end
        File.open("#{path}:#{key}", "wb") { |file| file.write(value.to_slice) }
      {% elsif flag?(:darwin) %}
        run_tool("xattr", ["-w", key, value, path])
      {% else %}
        run_tool("setfattr", ["-n", key, "-v", value, path])
      {% end %}
    rescue error : XAttrWriteError
      raise error
    rescue error : File::Error | IO::Error
      raise XAttrWriteError.new(
        error.message || "Unable to write extended attribute",
        classify(error.message.to_s),
        error,
      )
    end

    private def run_tool(command : String, arguments : Array(String))
      unless @process_runner.executable_available?(command)
        raise XAttrWriteError.new(
          "Couldn't find #{command} to write extended attributes",
          XAttrFailureReason::Unsupported,
        )
      end
      result = @process_runner.run(command, arguments)
      return if result.success?
      message = result.error.strip
      message = "exit code #{result.exit_code}" if message.empty?
      raise XAttrWriteError.new(message, classify(message))
    end

    private def classify(message : String) : XAttrFailureReason
      normalized = message.downcase
      return XAttrFailureReason::NoSpace if normalized.includes?("no space") ||
                                            normalized.includes?("quota")
      return XAttrFailureReason::ValueTooLong if normalized.includes?("too long") ||
                                                 normalized.includes?("too large")
      return XAttrFailureReason::Unsupported if normalized.includes?("not supported") ||
                                                normalized.includes?("invalid function")
      XAttrFailureReason::Other
    end
  end
end
