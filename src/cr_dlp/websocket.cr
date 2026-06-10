require "http/web_socket"
require "openssl/sha1"

module CrDlp
  module Networking
    class WebSocketResponse < Response
      getter protocol : String?
      getter? closed = false

      @send_mutex = Mutex.new
      @receive_mutex = Mutex.new

      def initialize(
        url : String,
        headers : Hash(String, String),
        reason : String?,
        @socket : HTTP::WebSocket::Protocol,
        @protocol : String? = nil,
      )
        super(url, 101, headers, Bytes.empty, reason)
      end

      def send(message : String)
        send_frame { @socket.send(message) }
      end

      def success? : Bool
        true
      end

      def send(message : Bytes)
        send_frame { @socket.send(message) }
      end

      def recv : String | Bytes
        @receive_mutex.synchronize do
          raise RequestError.new("WebSocket connection is closed") if closed?
          receive_message
        end
      rescue error : RequestError
        raise error
      rescue error
        close_transport
        raise RequestError.new("Unable to receive WebSocket message: #{error.message}", cause: error)
      end

      def close(code : HTTP::WebSocket::CloseCode? = nil, message : String? = nil)
        return if closed?
        @closed = true
        @socket.close(code, message)
      rescue
        close_transport
      end

      private def send_frame(&)
        @send_mutex.synchronize do
          raise RequestError.new("WebSocket connection is closed") if closed?
          yield
        end
      rescue error : RequestError
        raise error
      rescue error
        close_transport
        raise RequestError.new("Unable to send WebSocket message: #{error.message}", cause: error)
      end

      private def receive_message : String | Bytes
        buffer = Bytes.new(16 * 1024)
        message = IO::Memory.new
        message_type = nil.as(HTTP::WebSocket::Protocol::Opcode?)

        loop do
          packet = @socket.receive(buffer)
          case packet.opcode
          when .ping?
            @socket.pong(String.new(buffer[0, packet.size]))
          when .pong?
          when .close?
            respond_to_close(buffer[0, packet.size])
            raise RequestError.new("WebSocket connection was closed")
          when .text?, .binary?
            message_type ||= packet.opcode
            message.write(buffer[0, packet.size])
            if packet.final
              bytes = message.to_slice
              return message_type.text? ? String.new(bytes) : bytes.dup
            end
          when .continuation?
            # Protocol#receive resolves continuation frames to their message opcode.
          end
        end
      end

      private def respond_to_close(payload : Bytes)
        @closed = true
        code = nil.as(HTTP::WebSocket::CloseCode?)
        message = nil.as(String?)
        if payload.size >= 2
          value = IO::ByteFormat::NetworkEndian.decode(UInt16, payload[0, 2]).to_i
          code = HTTP::WebSocket::CloseCode.new(value)
          message = String.new(payload[2, payload.size - 2]) if payload.size > 2
        end
        @socket.close(code, message)
      rescue
        close_transport
      end

      private def close_transport
        @closed = true
        @socket.close
      rescue
      end
    end

    class CrystalWebSocketHandler < RequestHandler
      getter timeout : Time::Span
      getter verify_tls : Bool
      getter proxy : String?

      def initialize(
        @timeout = 20.seconds,
        @verify_tls = true,
        @default_headers = CrystalHttpHandler::DEFAULT_HEADERS,
        @cookie_jar : CookieJar? = nil,
        @proxy : String? = nil,
        @client_certificate : String? = nil,
        @client_certificate_key : String? = nil,
      )
      end

      def key : String
        "CrystalWebSocket"
      end

      def supports?(request : Request) : Bool
        URI.parse(request.url).scheme.in?("ws", "wss")
      rescue URI::Error
        false
      end

      def send(request : Request) : Response
        unless request.method == "GET" && request.body.nil?
          raise UnsupportedRequest.new("WebSocket requests must use GET without a body")
        end

        uri = URI.parse(request.url).normalize!
        host = uri.hostname || raise RequestError.new("WebSocket URL has no host")
        port = uri.port || (uri.scheme == "wss" ? 443 : 80)
        io = connect(uri, host, port)
        perform_handshake(request, uri, host, port, io)
      rescue error : HttpError | UnsupportedRequest
        raise error
      rescue error : URI::Error
        raise RequestError.new("Invalid WebSocket URL #{request.url}", cause: error)
      rescue error : RequestError
        raise error
      rescue error
        raise RequestError.new("Unable to connect to WebSocket #{request.url}: #{error.message}", cause: error)
      end

      def download(
        request : Request,
        destination : IO,
        progress : Proc(Int64, Int64?, Nil)? = nil,
      ) : Response
        raise UnsupportedRequest.new("WebSocket connections cannot be used as streamed HTTP downloads")
      end

      def probe(request : Request, max_bytes = 1024) : Response
        raise UnsupportedRequest.new("WebSocket connections cannot be probed as HTTP resources")
      end

      private def connect(uri : URI, host : String, port : Int32) : IO
        socket = if proxy_uri = proxy_for(uri)
                   Socks.connect(proxy_uri, host, port, @timeout)
                 else
                   TCPSocket.new(host, port, connect_timeout: @timeout.total_seconds)
                 end
        socket.read_timeout = @timeout
        socket.write_timeout = @timeout
        return socket unless uri.scheme == "wss"

        context = tls_context
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

      private def tls_context : OpenSSL::SSL::Context::Client
        context = OpenSSL::SSL::Context::Client.new
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE unless @verify_tls
        if certificate = @client_certificate
          context.certificate_chain = certificate
          context.private_key = @client_certificate_key || certificate
        end
        context
      end

      private def perform_handshake(
        request : Request,
        uri : URI,
        host : String,
        port : Int32,
        io : IO,
      ) : WebSocketResponse
        key = Base64.strict_encode(Random::Secure.random_bytes(16))
        headers = request_headers(request, uri)
        headers["Host"] ||= authority(uri, host, port)
        headers["Connection"] = "Upgrade"
        headers["Upgrade"] = "websocket"
        headers["Sec-WebSocket-Version"] = HTTP::WebSocket::Protocol::VERSION
        headers["Sec-WebSocket-Key"] = key

        HTTP::Request.new("GET", escaped_request_target(uri), headers).to_io(io)
        io.flush
        response = HTTP::Client::Response.from_io(io, ignore_body: true)
        unless response.status.switching_protocols?
          io.close
          raise HttpError.new(
            response.status_code,
            request.url,
            response.status_message,
          )
        end

        expected = HTTP::WebSocket::Protocol.key_challenge(key)
        unless response.headers["Sec-WebSocket-Accept"]? == expected
          io.close
          raise RequestError.new("WebSocket server returned an invalid challenge response")
        end
        unless response.headers.includes_word?("Connection", "Upgrade") &&
               response.headers["Upgrade"]?.try(&.compare("websocket", case_insensitive: true).zero?)
          io.close
          raise RequestError.new("WebSocket server returned an invalid upgrade response")
        end

        selected_protocol = response.headers["Sec-WebSocket-Protocol"]?
        requested_protocols = headers["Sec-WebSocket-Protocol"]?.try do |value|
          value.split(',').map(&.strip)
        end
        if selected_protocol && (!requested_protocols || !requested_protocols.includes?(selected_protocol))
          io.close
          raise RequestError.new("WebSocket server selected an unrequested subprotocol")
        end

        response_headers = Hash(String, String).new
        response.headers.each { |name, values| response_headers[name] = values.join(", ") }
        @cookie_jar.try(&.store(response.headers, request.url))
        protocol = HTTP::WebSocket::Protocol.new(
          io,
          masked: true,
          sync_close: true,
          protocol: selected_protocol,
        )
        WebSocketResponse.new(
          request.url,
          response_headers,
          response.status_message,
          protocol,
          selected_protocol,
        )
      rescue error
        io.close unless io.closed?
        raise error
      end

      private def request_headers(request : Request, uri : URI) : HTTP::Headers
        headers = HTTP::Headers.new
        @default_headers.each { |name, value| headers[name] = value }
        request.headers.each { |name, value| headers[name] = value }
        if user = uri.user
          headers["Authorization"] ||= "Basic #{Base64.strict_encode("#{user}:#{uri.password || ""}")}"
        end
        unless headers.has_key?("Cookie")
          @cookie_jar.try(&.header_for(request.url)).try do |cookie|
            headers["Cookie"] = cookie
          end
        end
        headers
      end

      private def proxy_for(uri : URI) : URI?
        value = @proxy
        if value.nil?
          return if bypass_proxy?(uri)
          value = ENV["ALL_PROXY"]? || ENV["all_proxy"]?
        end
        return if value.nil? || value.empty?

        value = "http://#{value}" unless value.includes?("://")
        proxy_uri = URI.parse(value)
        unless proxy_uri.scheme.in?("socks", "socks4", "socks4a", "socks5", "socks5h")
          raise UnsupportedRequest.new("WebSocket handler only supports SOCKS proxies")
        end
        raise UnsupportedRequest.new("SOCKS proxy URL has no host") unless proxy_uri.hostname
        proxy_uri
      rescue error : URI::Error
        raise UnsupportedRequest.new("Invalid proxy URL: #{value}")
      end

      private def bypass_proxy?(uri : URI) : Bool
        host = uri.hostname.try(&.downcase) || return false
        port = uri.port || (uri.scheme == "wss" ? 443 : 80)
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

      private def authority(uri : URI, host : String, port : Int32) : String
        default_port = uri.scheme == "wss" ? 443 : 80
        display_host = host.includes?(':') ? "[#{host}]" : host
        port == default_port ? display_host : "#{display_host}:#{port}"
      end

      private def escaped_request_target(uri : URI) : String
        path = uri.path.empty? ? "/" : uri.path
        escaped = String.build do |output|
          bytes = path.to_slice
          index = 0
          while index < bytes.size
            byte = bytes[index]
            if byte == '%'.ord && index + 2 < bytes.size &&
               hex_byte?(bytes[index + 1]) && hex_byte?(bytes[index + 2])
              output.write(bytes[index, 3])
              index += 3
            elsif byte >= 0x80 || byte <= 0x20 || byte == 0x7f
              output << '%' << byte.to_s(16).upcase.rjust(2, '0')
              index += 1
            else
              output.write_byte(byte)
              index += 1
            end
          end
        end
        uri.query ? "#{escaped}?#{uri.query}" : escaped
      end

      private def hex_byte?(byte : UInt8) : Bool
        byte.in?('0'.ord.to_u8..'9'.ord.to_u8) ||
          byte.in?('a'.ord.to_u8..'f'.ord.to_u8) ||
          byte.in?('A'.ord.to_u8..'F'.ord.to_u8)
      end
    end
  end
end
