require "./spec_helper"

private def socks_read(io : IO, count : Int) : Bytes
  bytes = Bytes.new(count)
  io.read_fully(bytes)
  bytes
end

private def socks_read_string(io : IO) : String
  String.build do |result|
    loop do
      byte = io.read_byte.not_nil!
      break if byte == 0
      result.write_byte(byte)
    end
  end
end

private def socks_http_response(socket : IO, body : String)
  request = socket.gets("\r\n\r\n").not_nil!
  socket << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
  socket.flush
  request
end

describe CrDlp::Networking::Socks do
  it "uses a local IPv4 destination and user ID for SOCKS4" do
    server = TCPServer.new("127.0.0.1", 0)
    address = server.local_address.as(Socket::IPAddress)
    observed = Channel(Tuple(Bytes, String, String)).new(1)
    done = Channel(Nil).new

    spawn do
      socket = server.accept
      begin
        header = socks_read(socket, 8)
        user = socks_read_string(socket)
        socket.write(Bytes[0, 90, 0x9c, 0x40, 127, 0, 0, 1])
        socket.flush
        request = socks_http_response(socket, "socks4")
        observed.send({header, user, request})
      ensure
        socket.close
        done.send(nil)
      end
    end

    begin
      handler = CrDlp::Networking::CrystalHttpHandler.new(
        proxy: "socks4://fixture@127.0.0.1:#{address.port}"
      )
      response = handler.send(CrDlp::Networking::Request.new(
        "http://127.0.0.1:8080/video.mp4"
      ))
      header, user, request = observed.receive

      response.text.should eq("socks4")
      header.should eq(Bytes[4, 1, 0x1f, 0x90, 127, 0, 0, 1])
      user.should eq("fixture")
      request.should contain("GET /video.mp4 HTTP/1.1")
    ensure
      done.receive
      server.close
    end
  end

  it "delegates domain resolution to SOCKS4a" do
    server = TCPServer.new("127.0.0.1", 0)
    address = server.local_address.as(Socket::IPAddress)
    observed = Channel(Tuple(Bytes, String)).new(1)
    done = Channel(Nil).new

    spawn do
      socket = server.accept
      begin
        header = socks_read(socket, 8)
        socks_read_string(socket)
        domain = socks_read_string(socket)
        socket.write(Bytes[0, 90, 0, 80, 127, 0, 0, 1])
        socket.flush
        socks_http_response(socket, "socks4a")
        observed.send({header, domain})
      ensure
        socket.close
        done.send(nil)
      end
    end

    begin
      handler = CrDlp::Networking::CrystalHttpHandler.new(
        proxy: "socks4a://127.0.0.1:#{address.port}"
      )
      response = handler.send(CrDlp::Networking::Request.new(
        "http://media.example.test/video.mp4"
      ))
      header, domain = observed.receive

      response.text.should eq("socks4a")
      header[4, 4].should eq(Bytes[0, 0, 0, 0xff])
      domain.should eq("media.example.test")
    ensure
      done.receive
      server.close
    end
  end

  it "negotiates SOCKS5 username/password authentication and remote DNS" do
    server = TCPServer.new("127.0.0.1", 0)
    address = server.local_address.as(Socket::IPAddress)
    observed = Channel(Tuple(Bytes, String, String, String, Int32)).new(1)
    done = Channel(Nil).new

    spawn do
      socket = server.accept
      begin
        greeting = socks_read(socket, 2)
        methods = socks_read(socket, greeting[1])
        socket.write(Bytes[5, 2])
        socket.flush

        auth = socks_read(socket, 2)
        username = String.new(socks_read(socket, auth[1]))
        password_length = socks_read(socket, 1)[0]
        password = String.new(socks_read(socket, password_length))
        socket.write(Bytes[1, 0])
        socket.flush

        request = socks_read(socket, 4)
        domain_length = socks_read(socket, 1)[0]
        domain = String.new(socks_read(socket, domain_length))
        port_bytes = socks_read(socket, 2)
        port = (port_bytes[0].to_i << 8) | port_bytes[1]
        socket.write(Bytes[5, 0, 0, 1, 127, 0, 0, 1, 0x9c, 0x40])
        socket.flush
        socks_http_response(socket, "socks5h")
        observed.send({methods, username, password, domain, port})
      ensure
        socket.close
        done.send(nil)
      end
    end

    begin
      handler = CrDlp::Networking::CrystalHttpHandler.new(
        proxy: "socks5h://test:testpass@127.0.0.1:#{address.port}"
      )
      response = handler.send(CrDlp::Networking::Request.new(
        "http://media.example.test:8080/video.mp4"
      ))
      methods, username, password, domain, port = observed.receive

      response.text.should eq("socks5h")
      methods.should eq(Bytes[0, 2])
      username.should eq("test")
      password.should eq("testpass")
      domain.should eq("media.example.test")
      port.should eq(8080)
    ensure
      done.receive
      server.close
    end
  end

  it "resolves destination names locally for SOCKS5" do
    server = TCPServer.new("127.0.0.1", 0)
    address = server.local_address.as(Socket::IPAddress)
    address_type = Channel(UInt8).new(1)
    done = Channel(Nil).new

    spawn do
      socket = server.accept
      begin
        greeting = socks_read(socket, 2)
        socks_read(socket, greeting[1])
        socket.write(Bytes[5, 0])
        socket.flush

        request = socks_read(socket, 4)
        type = request[3]
        address_size = type == 1 ? 4 : 16
        socks_read(socket, address_size)
        socks_read(socket, 2)
        socket.write(Bytes[5, 0, 0, 1, 127, 0, 0, 1, 0, 80])
        socket.flush
        socks_http_response(socket, "local-dns")
        address_type.send(type)
      ensure
        socket.close
        done.send(nil)
      end
    end

    begin
      handler = CrDlp::Networking::CrystalHttpHandler.new(
        proxy: "socks5://127.0.0.1:#{address.port}"
      )
      response = handler.send(CrDlp::Networking::Request.new(
        "http://localhost/video.mp4"
      ))

      response.text.should eq("local-dns")
      address_type.receive.in?(1_u8, 4_u8).should be_true
    ensure
      done.receive
      server.close
    end
  end

  it "negotiates TLS to HTTPS origins after the SOCKS5 tunnel is established" do
    server = TCPServer.new("127.0.0.1", 0)
    address = server.local_address.as(Socket::IPAddress)
    observed = Channel(Tuple(String, Int32, String)).new(1)
    done = Channel(Nil).new

    spawn do
      socket = server.accept
      begin
        greeting = socks_read(socket, 2)
        socks_read(socket, greeting[1])
        socket.write(Bytes[5, 0])
        socket.flush

        request = socks_read(socket, 4)
        request[3].should eq(3)
        domain = String.new(socks_read(socket, socks_read(socket, 1)[0]))
        port_bytes = socks_read(socket, 2)
        port = (port_bytes[0].to_i << 8) | port_bytes[1]
        socket.write(Bytes[5, 0, 0, 1, 127, 0, 0, 1, 0x9c, 0x40])
        socket.flush

        context = OpenSSL::SSL::Context::Server.new
        certificate = File.expand_path("../test/testcert.pem", __DIR__)
        context.certificate_chain = certificate
        context.private_key = certificate
        tls = OpenSSL::SSL::Socket::Server.new(socket, context: context, sync_close: false)
        http_request = socks_http_response(tls, "secure-socks")
        observed.send({domain, port, http_request})
        tls.close
      ensure
        socket.close
        done.send(nil)
      end
    end

    begin
      handler = CrDlp::Networking::CrystalHttpHandler.new(
        verify_tls: false,
        proxy: "socks5h://127.0.0.1:#{address.port}",
      )
      response = handler.send(CrDlp::Networking::Request.new(
        "https://secure.example.test/video.mp4"
      ))
      domain, port, request = observed.receive

      response.text.should eq("secure-socks")
      domain.should eq("secure.example.test")
      port.should eq(443)
      request.should contain("GET /video.mp4 HTTP/1.1")
      request.should contain("Host: secure.example.test")
    ensure
      done.receive
      server.close
    end
  end

  it "reports SOCKS5 connection errors" do
    server = TCPServer.new("127.0.0.1", 0)
    address = server.local_address.as(Socket::IPAddress)
    done = Channel(Nil).new

    spawn do
      socket = server.accept
      begin
        greeting = socks_read(socket, 2)
        socks_read(socket, greeting[1])
        socket.write(Bytes[5, 0])
        socket.flush
        request = socks_read(socket, 4)
        case request[3]
        when 1
          socks_read(socket, 4)
        when 3
          socks_read(socket, socks_read(socket, 1)[0])
        when 4
          socks_read(socket, 16)
        end
        socks_read(socket, 2)
        socket.write(Bytes[5, 5, 0, 1, 0, 0, 0, 0, 0, 0])
        socket.flush
      ensure
        socket.close
        done.send(nil)
      end
    end

    begin
      handler = CrDlp::Networking::CrystalHttpHandler.new(
        proxy: "socks5h://127.0.0.1:#{address.port}"
      )
      expect_raises(CrDlp::RequestError, /connection refused/) do
        handler.send(CrDlp::Networking::Request.new("http://example.test/video.mp4"))
      end
    ensure
      done.receive
      server.close
    end
  end
end
