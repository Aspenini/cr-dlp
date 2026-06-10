require "socket"

module CrDlp
  module Networking
    module Socks
      extend self

      SOCKS4_ERRORS = {
        91_u8 => "request rejected or failed",
        92_u8 => "request rejected because the proxy cannot connect to identd",
        93_u8 => "request rejected because the user IDs do not match",
      }

      SOCKS5_ERRORS = {
        1_u8 => "general proxy failure",
        2_u8 => "connection not allowed by ruleset",
        3_u8 => "network unreachable",
        4_u8 => "host unreachable",
        5_u8 => "connection refused",
        6_u8 => "TTL expired",
        7_u8 => "command not supported",
        8_u8 => "address type not supported",
      }

      def connect(
        proxy : URI,
        destination_host : String,
        destination_port : Int32,
        timeout : Time::Span,
      ) : TCPSocket
        proxy_host = proxy.hostname ||
                     raise UnsupportedRequest.new("SOCKS proxy URL has no host")
        socket = TCPSocket.new(
          proxy_host,
          proxy.port || 1080,
          connect_timeout: timeout.total_seconds,
        )
        socket.read_timeout = timeout
        socket.write_timeout = timeout

        case proxy.scheme
        when "socks", "socks4"
          negotiate_socks4(socket, proxy, destination_host, destination_port, false, timeout)
        when "socks4a"
          negotiate_socks4(socket, proxy, destination_host, destination_port, true, timeout)
        when "socks5"
          negotiate_socks5(socket, proxy, destination_host, destination_port, false, timeout)
        when "socks5h"
          negotiate_socks5(socket, proxy, destination_host, destination_port, true, timeout)
        else
          raise UnsupportedRequest.new("Unsupported SOCKS proxy scheme: #{proxy.scheme}")
        end
        socket
      rescue error
        socket.try(&.close)
        raise error
      end

      private def negotiate_socks4(
        socket : TCPSocket,
        proxy : URI,
        host : String,
        port : Int32,
        remote_dns : Bool,
        timeout : Time::Span,
      )
        remote_host = nil.as(String?)
        address = if fields = Socket::IPAddress.parse_v4_fields?(host)
                    ipv4_bytes(fields)
                  elsif remote_dns
                    remote_host = punycode(host)
                    Bytes[0, 0, 0, 0xff]
                  else
                    resolved = resolve(host, port, Socket::Family::INET, timeout)
                    fields = Socket::IPAddress.parse_v4_fields?(resolved.address).not_nil!
                    ipv4_bytes(fields)
                  end

        packet = IO::Memory.new
        packet.write_byte(4_u8)
        packet.write_byte(1_u8)
        packet.write_bytes(port.to_u16, IO::ByteFormat::BigEndian)
        packet.write(address)
        packet << (proxy.user || "")
        packet.write_byte(0_u8)
        if remote_host
          packet << remote_host
          packet.write_byte(0_u8)
        end
        socket.write(packet.to_slice)
        socket.flush

        response = read_exact(socket, 8)
        unless response[0] == 0
          raise RequestError.new("Invalid SOCKS4 response version #{response[0]}")
        end
        unless response[1] == 90
          message = SOCKS4_ERRORS[response[1]]? || "unknown proxy error"
          raise RequestError.new("SOCKS4 proxy error #{response[1]}: #{message}")
        end
      end

      private def negotiate_socks5(
        socket : TCPSocket,
        proxy : URI,
        host : String,
        port : Int32,
        remote_dns : Bool,
        timeout : Time::Span,
      )
        user = proxy.user
        password = proxy.password
        methods = [0_u8]
        methods << 2_u8 if user && password
        socket.write(Bytes[5_u8, methods.size.to_u8])
        socket.write(Bytes.new(methods.size) { |index| methods[index] })
        socket.flush

        selection = read_exact(socket, 2)
        unless selection[0] == 5
          raise RequestError.new("Invalid SOCKS5 response version #{selection[0]}")
        end
        case selection[1]
        when 0
        when 2
          authenticate_socks5(socket, user, password)
        when 0xff
          raise RequestError.new("SOCKS5 proxy rejected all authentication methods")
        else
          raise RequestError.new("SOCKS5 proxy selected unsupported authentication method #{selection[1]}")
        end

        address_type, address = socks5_address(host, port, remote_dns, timeout)
        request = IO::Memory.new
        request.write(Bytes[5_u8, 1_u8, 0_u8, address_type])
        request.write(address)
        request.write_bytes(port.to_u16, IO::ByteFormat::BigEndian)
        socket.write(request.to_slice)
        socket.flush

        response = read_exact(socket, 4)
        unless response[0] == 5
          raise RequestError.new("Invalid SOCKS5 response version #{response[0]}")
        end
        unless response[1] == 0
          message = SOCKS5_ERRORS[response[1]]? || "unknown proxy error"
          raise RequestError.new("SOCKS5 proxy error #{response[1]}: #{message}")
        end
        consume_socks5_address(socket, response[3])
        read_exact(socket, 2)
      end

      private def authenticate_socks5(socket : TCPSocket, user : String?, password : String?)
        unless user && password
          raise RequestError.new("SOCKS5 proxy requires username/password authentication")
        end
        user_bytes = user.to_slice
        password_bytes = password.to_slice
        if user_bytes.size > 255 || password_bytes.size > 255
          raise RequestError.new("SOCKS5 proxy credentials cannot exceed 255 bytes")
        end

        packet = IO::Memory.new
        packet.write_byte(1_u8)
        packet.write_byte(user_bytes.size.to_u8)
        packet.write(user_bytes)
        packet.write_byte(password_bytes.size.to_u8)
        packet.write(password_bytes)
        socket.write(packet.to_slice)
        socket.flush

        response = read_exact(socket, 2)
        unless response[0] == 1 && response[1] == 0
          raise RequestError.new("SOCKS5 proxy authentication failed")
        end
      end

      private def socks5_address(
        host : String,
        port : Int32,
        remote_dns : Bool,
        timeout : Time::Span,
      ) : Tuple(UInt8, Bytes)
        if fields = Socket::IPAddress.parse_v4_fields?(host)
          return {1_u8, ipv4_bytes(fields)}
        end
        if fields = Socket::IPAddress.parse_v6_fields?(host)
          bytes = IO::Memory.new
          fields.each { |field| bytes.write_bytes(field, IO::ByteFormat::BigEndian) }
          return {4_u8, bytes.to_slice}
        end
        if remote_dns
          domain = punycode(host).to_slice
          raise RequestError.new("SOCKS5 destination name is too long") if domain.size > 255
          bytes = Bytes.new(domain.size + 1)
          bytes[0] = domain.size.to_u8
          bytes[1, domain.size].copy_from(domain)
          return {3_u8, bytes}
        end

        address = resolve(host, port, Socket::Family::UNSPEC, timeout)
        socks5_address(address.address, port, false, timeout)
      end

      private def consume_socks5_address(socket : TCPSocket, address_type : UInt8)
        case address_type
        when 1
          read_exact(socket, 4)
        when 3
          length = read_exact(socket, 1)[0]
          read_exact(socket, length)
        when 4
          read_exact(socket, 16)
        else
          raise RequestError.new("SOCKS5 proxy returned unknown address type #{address_type}")
        end
      end

      private def resolve(
        host : String,
        port : Int32,
        family : Socket::Family,
        timeout : Time::Span,
      ) : Socket::IPAddress
        addresses = Socket::Addrinfo.tcp(
          host,
          port,
          family: family,
          timeout: timeout,
        )
        address = addresses.first?.try(&.ip_address)
        address || raise RequestError.new("Unable to resolve SOCKS destination #{host}")
      rescue error : Socket::Error
        raise RequestError.new("Unable to resolve SOCKS destination #{host}: #{error.message}", cause: error)
      end

      private def punycode(host : String) : String
        URI::Punycode.to_ascii(host)
      rescue URI::Error
        host
      end

      private def ipv4_bytes(fields : UInt8[4]) : Bytes
        Bytes.new(4) { |index| fields[index] }
      end

      private def read_exact(io : IO, count : Int) : Bytes
        bytes = Bytes.new(count)
        io.read_fully(bytes)
        bytes
      rescue error : IO::EOFError
        raise RequestError.new("SOCKS proxy closed the connection during negotiation", cause: error)
      end
    end
  end
end
