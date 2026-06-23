require "http/client"
require "openssl"
require "base64"
require "socket"

module CrDlp
  module Networking
    class Request
      getter url : String
      getter method : String
      getter headers : Hash(String, String)
      getter body : Bytes?

      def initialize(
        @url : String,
        method : String? = nil,
        @headers = Hash(String, String).new,
        @body : Bytes? = nil,
      )
        @url = "http:#{@url}" if @url.starts_with?("//")
        @method = (method || (@body ? "POST" : "GET")).upcase
      end
    end

    class Response
      getter url : String
      getter status : Int32
      getter reason : String?
      getter headers : Hash(String, String)
      getter body : Bytes

      def initialize(
        @url : String,
        @status : Int32,
        @headers : Hash(String, String),
        @body : Bytes,
        @reason : String? = nil,
      )
      end

      def success? : Bool
        200 <= @status < 400
      end

      def text : String
        String.new(@body)
      end
    end

    abstract class RequestHandler
      abstract def key : String
      abstract def supports?(request : Request) : Bool
      abstract def send(request : Request) : Response

      def probe(request : Request, max_bytes = 1024) : Response
        send(request)
      end

      def download(
        request : Request,
        destination : IO,
        progress : Proc(Int64, Int64?, Nil)? = nil,
      ) : Response
        response = send(request)
        destination.write(response.body)
        progress.try(&.call(response.body.size.to_i64, response.body.size.to_i64))
        response
      end
    end

    class CrystalHttpHandler < RequestHandler
      DEFAULT_HEADERS = {
        "User-Agent"      => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Accept"          => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language" => "en-us,en;q=0.5",
        "Sec-Fetch-Mode"  => "navigate",
      }

      getter timeout : Time::Span
      getter verify_tls : Bool
      getter proxy : String?

      def initialize(
        @timeout = 20.seconds,
        @verify_tls = true,
        @default_headers = DEFAULT_HEADERS,
        @max_redirects = 10,
        @cookie_jar : CookieJar? = nil,
        @proxy : String? = nil,
      )
      end

      def key : String
        "CrystalHTTP"
      end

      def supports?(request : Request) : Bool
        scheme = URI.parse(request.url).scheme
        scheme == "http" || scheme == "https"
      rescue URI::Error
        false
      end

      def send(request : Request) : Response
        execute(request) do |response, final_url|
          body = response.body_io.gets_to_end
          build_response(response, final_url, body.to_slice)
        end
      rescue error : RequestError
        raise error
      rescue error
        raise RequestError.new("Unable to request #{request.url}: #{error.message}", cause: error)
      end

      def download(
        request : Request,
        destination : IO,
        progress : Proc(Int64, Int64?, Nil)? = nil,
      ) : Response
        execute(request) do |response, final_url|
          total = response.headers["Content-Length"]?.try(&.to_i64?)
          downloaded = 0_i64
          buffer = Bytes.new(64 * 1024)
          loop do
            count = response.body_io.read(buffer)
            break if count == 0
            destination.write(buffer[0, count])
            downloaded += count
            progress.try(&.call(downloaded, total))
          end
          build_response(response, final_url, Bytes.empty)
        end
      rescue error : RequestError
        raise error
      rescue error
        raise RequestError.new("Unable to download #{request.url}: #{error.message}", cause: error)
      end

      def probe(request : Request, max_bytes = 1024) : Response
        headers = request.headers.dup
        headers["Range"] = "bytes=0-#{Math.max(0, max_bytes - 1)}" unless headers.has_key?("Range")
        probe_request = Request.new(
          request.url,
          method: request.method,
          headers: headers,
          body: request.body,
        )
        execute(probe_request) do |response, final_url|
          buffer = Bytes.new(Math.max(1, max_bytes))
          count = response.body_io.read(buffer)
          build_response(response, final_url, buffer[0, count].dup)
        end
      rescue error : RequestError
        raise error
      rescue error
        raise RequestError.new("Unable to probe #{request.url}: #{error.message}", cause: error)
      end

      private def execute(initial_request : Request, &)
        request = initial_request
        redirects = 0
        loop do
          raise RequestError.new("Too many redirects for #{initial_request.url}") if redirects > @max_redirects
          uri = URI.parse(request.url)
          headers = request_headers(request, redirects == 0)
          client, request_target = client_for(uri, headers)
          begin
            body = request.body.try { |bytes| String.new(bytes) }
            redirected = nil.as(Request?)
            client.exec(request.method, request_target, headers, body) do |response|
              @cookie_jar.try(&.store(response.headers, request.url))
              if redirect?(response.status_code)
                location = response.headers["Location"]? ||
                           raise RequestError.new("Redirect response has no Location header")
                redirected_url = URI.parse(request.url).resolve(location).to_s
                method = response.status_code == 303 ? "GET" : request.method
                redirected_body = method == "GET" ? nil : request.body
                redirected_headers = request.headers.dup
                redirected_headers.delete("Cookie")
                redirected = Request.new(
                  redirected_url,
                  method: method,
                  headers: redirected_headers,
                  body: redirected_body,
                )
              else
                unless 200 <= response.status_code < 300
                  raise HttpError.new(response.status_code, request.url, response.status_message)
                end
                return yield response, request.url
              end
            end
            request = redirected.not_nil!
            redirects += 1
          ensure
            client.close
          end
        end
      end

      private def request_headers(request : Request, include_default_cookie : Bool) : HTTP::Headers
        headers = HTTP::Headers.new
        @default_headers.each do |name, value|
          next if name.downcase == "cookie" && !include_default_cookie
          headers[name] = value
        end
        request.headers.each { |name, value| headers[name] = value }
        unless headers.has_key?("Cookie")
          @cookie_jar.try(&.header_for(request.url)).try do |cookie|
            headers["Cookie"] = cookie
          end
        end
        headers
      end

      private def client_for(uri : URI, headers : HTTP::Headers) : Tuple(HTTP::Client, String)
        proxy_uri = proxy_for(uri)
        return {direct_client(uri), uri.request_target} unless proxy_uri

        case proxy_uri.scheme
        when "http", "https"
          if uri.scheme == "https"
            {tunneled_client(uri, proxy_uri), uri.request_target}
          else
            headers["Host"] = authority(uri)
            proxy_authorization(proxy_uri).try { |value| headers["Proxy-Authorization"] = value }
            {proxy_client(proxy_uri),
             absolute_request_target(uri)}
          end
        when "socks", "socks4", "socks4a", "socks5", "socks5h"
          {socks_client(uri, proxy_uri), uri.request_target}
        else
          raise UnsupportedRequest.new("Unsupported proxy scheme: #{proxy_uri.scheme}")
        end
      end

      private def direct_client(uri : URI) : HTTP::Client
        client = HTTP::Client.new(uri)
        configure_client(client)
        if (tls = client.tls?) && !@verify_tls
          tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE
        end
        client
      end

      private def configured_client(host : String, port : Int32, tls) : HTTP::Client
        client = HTTP::Client.new(host, port, tls: tls)
        configure_client(client)
        client
      end

      private def proxy_client(proxy_uri : URI) : HTTP::Client
        host = proxy_uri.hostname.not_nil!
        port = proxy_uri.port || (proxy_uri.scheme == "https" ? 443 : 80)
        return configured_client(host, port, false) unless proxy_uri.scheme == "https"

        context = OpenSSL::SSL::Context::Client.new
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE unless @verify_tls
        configured_client(host, port, context)
      end

      private def socks_client(origin : URI, proxy_uri : URI) : HTTP::Client
        host = origin.hostname.not_nil!
        port = origin.port || (origin.scheme == "https" ? 443 : 80)
        socket = Socks.connect(proxy_uri, host, port, @timeout)
        io = if origin.scheme == "https"
               context = OpenSSL::SSL::Context::Client.new
               context.verify_mode = OpenSSL::SSL::VerifyMode::NONE unless @verify_tls
               OpenSSL::SSL::Socket::Client.new(
                 socket,
                 context: context,
                 sync_close: true,
                 hostname: host,
               )
             else
               socket
             end
        client = HTTP::Client.new(io, origin.host.not_nil!, port)
        configure_client(client)
        client
      rescue error
        socket.try(&.close)
        raise error
      end

      private def configure_client(client : HTTP::Client)
        client.connect_timeout = @timeout
        client.read_timeout = @timeout
        client.write_timeout = @timeout
      end

      private def tunneled_client(origin : URI, proxy_uri : URI) : HTTP::Client
        proxy_io = proxy_connection(proxy_uri)

        origin_authority = authority(origin)
        proxy_io << "CONNECT #{origin_authority} HTTP/1.1\r\n"
        proxy_io << "Host: #{origin_authority}\r\n"
        proxy_authorization(proxy_uri).try do |value|
          proxy_io << "Proxy-Authorization: #{value}\r\n"
        end
        proxy_io << "Proxy-Connection: keep-alive\r\n\r\n"
        proxy_io.flush

        status_line = proxy_io.gets || raise RequestError.new("Proxy closed the CONNECT tunnel")
        match = status_line.match(/\AHTTP\/\d+(?:\.\d+)?\s+(\d{3})(?:\s+(.*))?\z/) ||
                raise RequestError.new("Invalid CONNECT response from proxy")
        status = match[1].to_i
        loop do
          line = proxy_io.gets || raise RequestError.new("Incomplete CONNECT response from proxy")
          break if line.empty?
        end
        unless status == 200
          proxy_io.close
          reason = match[2]?
          raise RequestError.new("Proxy CONNECT failed with HTTP #{status}#{reason ? " #{reason}" : ""}")
        end

        context = OpenSSL::SSL::Context::Client.new
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE unless @verify_tls
        ssl = OpenSSL::SSL::Socket::Client.new(
          proxy_io,
          context: context,
          sync_close: true,
          hostname: origin.hostname,
        )
        client = HTTP::Client.new(ssl, origin.host.not_nil!, origin.port || 443)
        configure_client(client)
        client
      rescue error
        proxy_io.try(&.close)
        raise error
      end

      private def proxy_connection(proxy_uri : URI) : IO
        host = proxy_uri.hostname.not_nil!
        port = proxy_uri.port || (proxy_uri.scheme == "https" ? 443 : 80)
        socket = TCPSocket.new(host, port, connect_timeout: @timeout.total_seconds)
        socket.read_timeout = @timeout
        socket.write_timeout = @timeout
        return socket unless proxy_uri.scheme == "https"

        context = OpenSSL::SSL::Context::Client.new
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE unless @verify_tls
        OpenSSL::SSL::Socket::Client.new(
          socket,
          context: context,
          sync_close: true,
          hostname: host,
        )
      rescue error
        socket.try(&.close)
        raise error
      end

      private def proxy_for(uri : URI) : URI?
        value = @proxy
        if value.nil?
          return if bypass_proxy?(uri)
          value = proxy_from_environment(uri.scheme)
        end
        return if value.nil? || value.empty?

        value = "http://#{value}" unless value.includes?("://")
        proxy_uri = URI.parse(value)
        raise UnsupportedRequest.new("Proxy URL has no host: #{value}") unless proxy_uri.hostname
        proxy_uri
      rescue error : URI::Error
        raise UnsupportedRequest.new("Invalid proxy URL: #{value}")
      end

      private def proxy_from_environment(scheme : String?) : String?
        names = scheme == "https" ? %w[HTTPS_PROXY https_proxy] : %w[HTTP_PROXY http_proxy]
        (names + %w[ALL_PROXY all_proxy]).each do |name|
          value = ENV[name]?
          return value if value && !value.empty?
        end
        nil
      end

      private def bypass_proxy?(uri : URI) : Bool
        host = uri.hostname.try(&.downcase) || return false
        port = uri.port || (uri.scheme == "https" ? 443 : 80)
        no_proxy = ENV["NO_PROXY"]? || ENV["no_proxy"]?
        return false unless no_proxy

        no_proxy.split(',').any? do |raw_entry|
          entry = raw_entry.strip.downcase
          next false if entry.empty?
          next true if entry == "*"

          entry_host, entry_port = split_no_proxy(entry)
          next false if entry_port && entry_port != port
          normalized = entry_host.lstrip('.')
          host == normalized || host.ends_with?(".#{normalized}")
        end
      end

      private def split_no_proxy(entry : String) : Tuple(String, Int32?)
        if entry.starts_with?('[')
          closing = entry.index(']')
          return {entry, nil} unless closing
          port = entry.byte_at?(closing + 1) == ':'.ord ? entry[(closing + 2)..].to_i? : nil
          {entry[1, closing - 1], port}
        elsif entry.count(':') == 1
          host, port = entry.split(':', 2)
          {host, port.to_i?}
        else
          {entry, nil}
        end
      end

      private def proxy_authorization(proxy_uri : URI) : String?
        user = proxy_uri.user
        return unless user
        credentials = "#{user}:#{proxy_uri.password || ""}"
        "Basic #{Base64.strict_encode(credentials)}"
      end

      private def absolute_request_target(uri : URI) : String
        "#{uri.scheme}://#{authority(uri)}#{uri.request_target}"
      end

      private def authority(uri : URI) : String
        host = uri.host.not_nil!
        port = uri.port
        default_port = uri.scheme == "https" ? 443 : 80
        port && port != default_port ? "#{host}:#{port}" : host
      end

      private def redirect?(status : Int32) : Bool
        status.in?(301, 302, 303, 307, 308)
      end

      private def build_response(
        response : HTTP::Client::Response,
        url : String,
        body : Bytes,
      ) : Response
        headers = Hash(String, String).new
        response.headers.each { |name, values| headers[name] = values.join(", ") }
        Response.new(url, response.status_code, headers, body, response.status_message)
      end
    end

    class CurlImpersonateHandler < RequestHandler
      getter impersonate : ImpersonateTarget
      getter timeout : Time::Span
      getter proxy : String?
      getter cookie_jar : CookieJar?

      def initialize(
        @impersonate : ImpersonateTarget,
        @timeout = 20.seconds,
        @cookie_jar : CookieJar? = nil,
        @proxy : String? = nil,
      )
      end

      def key : String
        "curl-impersonate"
      end

      def supports?(request : Request) : Bool
        scheme = URI.parse(request.url).scheme
        return false unless scheme == "http" || scheme == "https"
        !resolved_entry.nil?
      rescue URI::Error
        false
      end

      def send(request : Request) : Response
        entry = resolved_entry
        raise UnsupportedRequest.new("No impersonate target available for #{@impersonate}") unless entry
        execute_curl(entry.binary, request)
      end

      def download(
        request : Request,
        destination : IO,
        progress : Proc(Int64, Int64?, Nil)? = nil,
      ) : Response
        response = send(request)
        destination.write(response.body)
        progress.try(&.call(response.body.size.to_i64, response.body.size.to_i64))
        response
      end

      def probe(request : Request, max_bytes = 1024) : Response
        headers = request.headers.dup
        headers["Range"] = "bytes=0-#{Math.max(0, max_bytes - 1)}" unless headers.has_key?("Range")
        send(Request.new(request.url, method: request.method, headers: headers, body: request.body))
      end

      private def resolved_entry : ImpersonateTargets::Entry?
        @resolved_entry ||= ImpersonateTargets.resolve(@impersonate)
      end

      @resolved_entry : ImpersonateTargets::Entry?

      private def execute_curl(binary : String, request : Request) : Response
        args = ["-sS", "-X", request.method, "-D", "-", "-o", "-", "--max-time", @timeout.total_seconds.to_i.to_s]
        proxy.try { |value| args.concat(["--proxy", value]) }
        request.headers.each { |name, value| args.concat(["-H", "#{name}: #{value}"]) }
        unless request.headers.has_key?("Cookie")
          @cookie_jar.try(&.header_for(request.url)).try do |cookie|
            args.concat(["-H", "Cookie: #{cookie}"])
          end
        end
        args << request.url
        stdout = IO::Memory.new
        stderr = IO::Memory.new
        status = Process.run(binary, args, output: stdout, error: stderr)
        unless status.success?
          message = stderr.to_s.strip
          message = "curl impersonation failed with exit #{status.exit_code}" if message.empty?
          raise RequestError.new(message)
        end
        parse_curl_response(request.url, stdout.to_slice)
      rescue error : RequestError
        raise error
      rescue error
        raise RequestError.new("Unable to impersonate request to #{request.url}: #{error.message}", cause: error)
      end

      private def parse_curl_response(url : String, data : Bytes) : Response
        crlf = "\r\n\r\n".bytes
        lf = "\n\n".bytes
        separator = data.index(crlf) || data.index(lf) ||
                    raise RequestError.new("Invalid impersonated HTTP response")
        header_bytes = data[0, separator]
        body_start = separator + (data[separator, crlf.size]? == crlf ? 4 : 2)
        body = data[body_start..]
        header_text = String.new(header_bytes)
        lines = header_text.split('\n').map(&.chomp)
        status_line = lines.first? || raise RequestError.new("Missing HTTP status line")
        match = status_line.match(/\AHTTP\/\d+(?:\.\d+)?\s+(\d{3})(?:\s+(.*))?\z/) ||
                raise RequestError.new("Invalid HTTP status line")
        status = match[1].to_i
        reason = match[2]?
        headers = Hash(String, String).new
        lines[1..]?.try &.each do |line|
          next if line.empty?
          name, value = line.split(':', 2, remove_empty: false)
          next unless value
          headers[name.strip] = value.strip
        end
        Response.new(url, status, headers, body.to_slice, reason)
      end
    end

    class RequestDirector
      getter handlers : Array(RequestHandler)

      def initialize(@handlers = [] of RequestHandler)
      end

      def add(handler : RequestHandler)
        existing = @handlers.index { |candidate| candidate.key == handler.key }
        if existing
          @handlers[existing] = handler
        else
          @handlers << handler
        end
      end

      def send(request : Request) : Response
        failures = [] of String
        @handlers.each do |handler|
          next unless handler.supports?(request)
          begin
            return handler.send(request)
          rescue error : UnsupportedRequest
            failures << "#{handler.key}: #{error.message}"
          end
        end
        detail = failures.empty? ? "" : " (#{failures.join("; ")})"
        raise UnsupportedRequest.new("No request handler supports #{request.url}#{detail}")
      end

      def download(
        request : Request,
        destination : IO,
        progress : Proc(Int64, Int64?, Nil)? = nil,
      ) : Response
        failures = [] of String
        @handlers.each do |handler|
          next unless handler.supports?(request)
          begin
            return handler.download(request, destination, progress)
          rescue error : UnsupportedRequest
            failures << "#{handler.key}: #{error.message}"
          end
        end
        detail = failures.empty? ? "" : " (#{failures.join("; ")})"
        raise UnsupportedRequest.new("No request handler supports #{request.url}#{detail}")
      end

      def probe(request : Request, max_bytes = 1024) : Response
        failures = [] of String
        @handlers.each do |handler|
          next unless handler.supports?(request)
          begin
            return handler.probe(request, max_bytes)
          rescue error : UnsupportedRequest
            failures << "#{handler.key}: #{error.message}"
          end
        end
        detail = failures.empty? ? "" : " (#{failures.join("; ")})"
        raise UnsupportedRequest.new("No request handler supports #{request.url}#{detail}")
      end

      def open_websocket(request : Request) : WebSocketResponse
        response = send(request)
        response.as?(WebSocketResponse) ||
          raise RequestError.new("Request did not return a WebSocket connection")
      end
    end
  end
end
