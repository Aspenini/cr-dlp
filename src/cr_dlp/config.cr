module CrDlp
  module Config
    extend self

    def tokenize(source : String) : Array(String)
      arguments = [] of String
      token = String::Builder.new
      quote = nil.as(Char?)
      escaped = false

      source.each_char do |char|
        if escaped
          token << char
          escaped = false
        elsif char == '\\'
          escaped = true
        elsif quote
          if char == quote
            quote = nil
          else
            token << char
          end
        elsif char == '"' || char == '\''
          quote = char
        elsif char.whitespace?
          unless token.empty?
            arguments << token.to_s
            token = String::Builder.new
          end
        elsif char == '#'
          break
        else
          token << char
        end
      end
      raise UsageError.new("Unterminated quote in configuration") if quote
      arguments << token.to_s unless token.empty?
      arguments
    end

    def read(path : String) : Array(String)
      arguments = [] of String
      File.each_line(path) { |line| arguments.concat(tokenize(line)) }
      arguments
    rescue error : File::Error
      raise UsageError.new("Unable to read configuration #{path}: #{error.message}", cause: error)
    end
  end
end
