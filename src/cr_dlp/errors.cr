module CrDlp
  class Error < Exception
  end

  class UsageError < Error
  end

  class ExtractorError < Error
    getter expected : Bool

    def initialize(message : String, @expected = false, cause : Exception? = nil)
      super(message, cause)
    end
  end

  class UnsupportedUrlError < ExtractorError
    def initialize(url : String)
      super("Unsupported URL: #{url}", true)
    end
  end

  class DownloadError < Error
  end

  class CryptoError < Error
  end

  class PostProcessingError < Error
  end

  class RequestError < Error
  end

  class UpdateError < Error
  end

  class UnsupportedRequest < RequestError
  end

  class HttpError < RequestError
    getter status : Int32
    getter url : String

    def initialize(@status : Int32, @url : String, message : String? = nil)
      super(message || "HTTP Error #{@status} for #{@url}")
    end
  end
end
