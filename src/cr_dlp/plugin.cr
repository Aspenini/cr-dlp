module CrDlp
  module Plugin
    PROTOCOL_VERSION = "1.0"

    class Manifest
      include JSON::Serializable

      getter name : String
      getter executable : String
      getter arguments : Array(String) = [] of String
      getter capabilities : Array(String) = [] of String
      getter extractors : Array(String) = [] of String
      getter priority : Int32 = 0
      getter protocol_version : String = PROTOCOL_VERSION

      def validate!
        unless @protocol_version == PROTOCOL_VERSION
          raise UsageError.new("Plugin #{@name} uses unsupported protocol #{@protocol_version}")
        end
        raise UsageError.new("Plugin #{@name} has no executable") if @executable.empty?
      end
    end

    class RpcClient
      getter manifest : Manifest

      @process : Process?
      @input : IO?
      @output : IO?
      @next_id = 0_i64

      def initialize(@manifest : Manifest)
        @manifest.validate!
      end

      def call(method : String, params : JSON::Any) : JSON::Any
        start unless @process
        id = (@next_id += 1)
        request = {
          "jsonrpc" => JSON::Any.new("2.0"),
          "id"      => JSON::Any.new(id),
          "method"  => JSON::Any.new(method),
          "params"  => params,
        }
        @input.not_nil!.puts(request.to_json)
        @input.not_nil!.flush

        loop do
          line = @output.not_nil!.gets || raise Error.new("Plugin #{@manifest.name} closed its output")
          response = JSON.parse(line).as_h
          next unless response["id"]?.try(&.as_i64?) == id
          if error = response["error"]?
            raise Error.new("Plugin #{@manifest.name}: #{error.to_json}")
          end
          return response["result"]? || JSON::Any.new(nil)
        end
      end

      def close
        @input.try(&.close)
        @output.try(&.close)
        @process.try(&.terminate)
        @process = nil
      end

      private def start
        input = IO::Memory.new
        output = IO::Memory.new
        # Process pipes are connected explicitly so plugins remain language-neutral.
        process = Process.new(
          @manifest.executable,
          @manifest.arguments,
          input: Process::Redirect::Pipe,
          output: Process::Redirect::Pipe,
          error: Process::Redirect::Inherit,
        )
        @process = process
        @input = process.input
        @output = process.output
      rescue error
        raise Error.new("Unable to start plugin #{@manifest.name}: #{error.message}", cause: error)
      end
    end
  end
end
