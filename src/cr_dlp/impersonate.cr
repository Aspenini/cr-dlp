module CrDlp
  struct ImpersonateTarget
    getter client : String?
    getter version : String?
    getter os : String?
    getter os_version : String?

    def initialize(
      @client : String? = nil,
      @version : String? = nil,
      @os : String? = nil,
      @os_version : String? = nil,
    )
      if @version && !@client
        raise UsageError.new("client is required if version is set")
      end
      if @os_version && !@os
        raise UsageError.new("os is required if os_version is set")
      end
    end

    def matches?(other : ImpersonateTarget) : Bool
      (client.nil? || other.client.nil? || client == other.client) &&
        (version.nil? || other.version.nil? || version == other.version) &&
        (os.nil? || other.os.nil? || os == other.os) &&
        (os_version.nil? || other.os_version.nil? || os_version == other.os_version)
    end

    def to_s(io : IO) : Nil
      client_part = [client, version].compact.join("-")
      os_part = [os, os_version].compact.join("-")
      if client_part.empty? && os_part.empty?
        io << ""
      elsif os_part.empty?
        io << client_part
      elsif client_part.empty?
        io << ":#{os_part}"
      else
        io << "#{client_part}:#{os_part}"
      end
    end

    def to_s : String
      String.build { |io| to_s(io) }
    end

    def self.from_str(target : String) : self
      match = target.match(
        /^(?:(?<client>[^:-]+)(?:-(?<version>[^:-]+))?)?(?::(?:(?<os>[^:-]+)(?:-(?<os_version>[^:-]+))?)?)?$/
      )
      raise UsageError.new("Invalid impersonate target \"#{target}\"") unless match
      new(
        client: match["client"]?,
        version: match["version"]?,
        os: match["os"]?,
        os_version: match["os_version"]?,
      )
    end

    def self.parse_option(value : String?) : ImpersonateTarget?
      return unless value
      return new if value.empty?
      from_str(value.downcase)
    end
  end

  module ImpersonateTargets
    extend self

    record Entry, target : ImpersonateTarget, binary : String, source : String

    # Mirrors yt-dlp curl_cffi target names; binaries are resolved on PATH.
    KNOWN_TARGETS = [
      Entry.new(ImpersonateTarget.new("chrome", "99", "windows", "10"), "curl_chrome99", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("chrome", "100", "windows", "10"), "curl_chrome100", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("chrome", "101", "windows", "10"), "curl_chrome101", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("chrome", "104", "windows", "10"), "curl_chrome104", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("chrome", "107", "windows", "10"), "curl_chrome107", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("chrome", "110", "windows", "10"), "curl_chrome110", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("chrome", "116", "windows", "10"), "curl_chrome116", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("chrome", "119", "macos", "14"), "curl_chrome119", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("chrome", "120", "macos", "14"), "curl_chrome120", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("chrome", "123", "macos", "14"), "curl_chrome123", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("chrome", "124", "macos", "14"), "curl_chrome124", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("chrome", "131", "macos", "14"), "curl_chrome131", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("chrome", "133", "macos", "15"), "curl_chrome133a", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("chrome", "136", "macos", "15"), "curl_chrome136", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("chrome", "142", "macos", "26"), "curl_chrome142", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("chrome", "145", "macos", "26"), "curl_chrome145", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("chrome", "146", "macos", "26"), "curl_chrome146", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("edge", "99", "windows", "10"), "curl_edge99", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("edge", "101", "windows", "10"), "curl_edge101", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("firefox", "133", "macos", "14"), "curl_firefox133", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("firefox", "135", "macos", "14"), "curl_firefox135", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("firefox", "144", "macos", "26"), "curl_firefox144", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("firefox", "147", "macos", "26"), "curl_firefox147", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("safari", "15.3", "macos", "11"), "curl_safari15_3", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("safari", "15.5", "macos", "12"), "curl_safari15_5", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("safari", "17.0", "macos", "14"), "curl_safari17_0", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("safari", "17.2", "ios", "17.2"), "curl_safari17_2_ios", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("safari", "18.0", "macos", "15"), "curl_safari18_0", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("safari", "18.4", "macos", "15"), "curl_safari18_4", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("safari", "26.0", "macos", "26"), "curl_safari260", "curl-impersonate"),
      Entry.new(ImpersonateTarget.new("tor", "14.5", "macos", "14"), "curl_tor145", "curl-impersonate"),
    ]

    def available : Array(Entry)
      KNOWN_TARGETS.select { |entry| binary_available?(entry.binary) }
    end

    def resolve(requested : ImpersonateTarget) : Entry?
      available.reverse_each do |entry|
        return entry if requested.matches?(entry.target)
      end
      nil
    end

    def binary_available?(name : String) : Bool
      stdout = IO::Memory.new
      {% if flag?(:win32) %}
        status = Process.run(
          "where",
          [name],
          output: stdout,
          error: Process::Redirect::Close,
        )
        status.success? && !stdout.to_s.strip.empty?
      {% else %}
        status = Process.run(
          "sh",
          ["-c", "command -v #{name.shellescape}"],
          output: stdout,
          error: Process::Redirect::Close,
        )
        status.success?
      {% end %}
    rescue IO::Error
      false
    end
  end
end
