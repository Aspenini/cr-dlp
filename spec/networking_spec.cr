require "./spec_helper"

describe CrDlp::Networking::CrystalHttpHandler do
  it "downloads plain HTTP responses without probing a nonexistent TLS context" do
    server = TCPServer.new("127.0.0.1", 0)
    address = server.local_address.as(Socket::IPAddress)
    done = Channel(Nil).new

    spawn do
      socket = server.accept
      begin
        socket.gets("\r\n\r\n")
        socket << "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nfixture"
        socket.flush
      ensure
        socket.close
        done.send(nil)
      end
    end

    begin
      handler = CrDlp::Networking::CrystalHttpHandler.new
      response = handler.send(CrDlp::Networking::Request.new(
        "http://127.0.0.1:#{address.port}/file.mp4"
      ))
      response.status.should eq(200)
      response.text.should eq("fixture")
    ensure
      done.receive
      server.close
    end
  end

  it "follows relative redirects and applies default request headers" do
    user_agent = Channel(String).new(1)
    server = HTTP::Server.new do |context|
      case context.request.path
      when "/redirect"
        context.response.status = HTTP::Status::FOUND
        context.response.headers["Location"] = "/final"
      when "/final"
        user_agent.send(context.request.headers["User-Agent"])
        context.response.print("redirected")
      else
        context.response.status = HTTP::Status::NOT_FOUND
      end
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    begin
      handler = CrDlp::Networking::CrystalHttpHandler.new(
        default_headers: {"User-Agent" => "cr-dlp-test"}
      )
      response = handler.send(CrDlp::Networking::Request.new(
        "http://127.0.0.1:#{address.port}/redirect"
      ))
      response.url.should eq("http://127.0.0.1:#{address.port}/final")
      response.text.should eq("redirected")
      user_agent.receive.should eq("cr-dlp-test")
    ensure
      server.close
    end
  end

  it "stores redirect cookies and removes an explicit Cookie header before redirecting" do
    received = Channel(String).new(2)
    server = HTTP::Server.new do |context|
      received.send(context.request.headers["Cookie"]? || "")
      case context.request.path
      when "/redirect"
        context.response.status = HTTP::Status::FOUND
        context.response.headers["Location"] = "/final"
        context.response.headers["Set-Cookie"] = "redirected=yes; Path=/final"
      when "/final"
        context.response.print("done")
      else
        context.response.status = HTTP::Status::NOT_FOUND
      end
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    begin
      jar = CrDlp::CookieJar.new
      jar.add(CrDlp::CookieJar::Cookie.new(
        "127.0.0.1",
        false,
        "/",
        false,
        nil,
        "stored",
        "value",
      ))
      handler = CrDlp::Networking::CrystalHttpHandler.new(cookie_jar: jar, proxy: "")
      response = handler.send(CrDlp::Networking::Request.new(
        "http://127.0.0.1:#{address.port}/redirect",
        headers: {"Cookie" => "explicit=value"},
      ))

      response.text.should eq("done")
      received.receive.should eq("explicit=value")
      redirected_cookie = received.receive
      redirected_cookie.should contain("redirected=yes")
      redirected_cookie.should contain("stored=value")
      redirected_cookie.should_not contain("explicit=value")
    ensure
      server.close
    end
  end

  it "uses absolute request targets and Basic authentication for HTTP proxies" do
    server = TCPServer.new("127.0.0.1", 0)
    address = server.local_address.as(Socket::IPAddress)
    request_data = Channel(String).new(1)
    done = Channel(Nil).new

    spawn do
      socket = server.accept
      begin
        request = socket.gets("\r\n\r\n").not_nil!
        request_data.send(request)
        socket << "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nproxied"
        socket.flush
      ensure
        socket.close
        done.send(nil)
      end
    end

    begin
      handler = CrDlp::Networking::CrystalHttpHandler.new(
        proxy: "http://user:password@127.0.0.1:#{address.port}"
      )
      response = handler.send(CrDlp::Networking::Request.new(
        "http://media.example.test:8080/video.mp4?quality=best"
      ))
      request = request_data.receive

      response.text.should eq("proxied")
      request.should contain("GET http://media.example.test:8080/video.mp4?quality=best HTTP/1.1")
      request.should contain("Host: media.example.test:8080")
      request.should contain("Proxy-Authorization: Basic dXNlcjpwYXNzd29yZA==")
    ensure
      done.receive
      server.close
    end
  end

  it "uses CONNECT for HTTPS origins through an HTTP proxy" do
    server = TCPServer.new("127.0.0.1", 0)
    address = server.local_address.as(Socket::IPAddress)
    connect_request = Channel(String).new(1)
    tunneled_request = Channel(String).new(1)
    done = Channel(Nil).new

    spawn do
      socket = server.accept
      begin
        connect = socket.gets("\r\n\r\n").not_nil!
        connect_request.send(connect)
        socket << "HTTP/1.1 200 Connection Established\r\n\r\n"
        socket.flush

        context = OpenSSL::SSL::Context::Server.new
        certificate = File.expand_path("../test/testcert.pem", __DIR__)
        context.certificate_chain = certificate
        context.private_key = certificate
        tls = OpenSSL::SSL::Socket::Server.new(socket, context: context, sync_close: false)
        request = tls.gets("\r\n\r\n").not_nil!
        tunneled_request.send(request)
        tls << "HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\ntunnel"
        tls.flush
        tls.close
      ensure
        socket.close
        done.send(nil)
      end
    end

    begin
      handler = CrDlp::Networking::CrystalHttpHandler.new(
        verify_tls: false,
        proxy: "http://user:password@127.0.0.1:#{address.port}",
      )
      response = handler.send(CrDlp::Networking::Request.new(
        "https://secure.example.test/video.mp4"
      ))
      connect = connect_request.receive
      tunneled = tunneled_request.receive

      response.text.should eq("tunnel")
      connect.should contain("CONNECT secure.example.test HTTP/1.1")
      connect.should contain("Proxy-Authorization: Basic dXNlcjpwYXNzd29yZA==")
      tunneled.should contain("GET /video.mp4 HTTP/1.1")
      tunneled.should contain("Host: secure.example.test")
      tunneled.should_not contain("Proxy-Authorization")
    ensure
      done.receive
      server.close
    end
  end

  it "sends HTTP origin requests through a TLS-encrypted HTTPS proxy" do
    server = TCPServer.new("127.0.0.1", 0)
    address = server.local_address.as(Socket::IPAddress)
    request_data = Channel(String).new(1)
    done = Channel(Nil).new

    spawn do
      socket = server.accept
      begin
        context = OpenSSL::SSL::Context::Server.new
        certificate = File.expand_path("../test/testcert.pem", __DIR__)
        context.certificate_chain = certificate
        context.private_key = certificate
        tls = OpenSSL::SSL::Socket::Server.new(socket, context: context, sync_close: false)
        request = tls.gets("\r\n\r\n").not_nil!
        request_data.send(request)
        tls << "HTTP/1.1 200 OK\r\nContent-Length: 9\r\nConnection: close\r\n\r\ntls-proxy"
        tls.flush
        tls.close
      ensure
        socket.close
        done.send(nil)
      end
    end

    begin
      handler = CrDlp::Networking::CrystalHttpHandler.new(
        verify_tls: false,
        proxy: "https://user:password@127.0.0.1:#{address.port}",
      )
      response = handler.send(CrDlp::Networking::Request.new(
        "http://media.example.test/video.mp4"
      ))
      request = request_data.receive

      response.text.should eq("tls-proxy")
      request.should contain("GET http://media.example.test/video.mp4 HTTP/1.1")
      request.should contain("Proxy-Authorization: Basic dXNlcjpwYXNzd29yZA==")
    ensure
      done.receive
      server.close
    end
  end

  it "nests origin TLS inside an HTTPS proxy CONNECT tunnel" do
    server = TCPServer.new("127.0.0.1", 0)
    address = server.local_address.as(Socket::IPAddress)
    observed = Channel(Tuple(String, String)).new(1)
    done = Channel(Nil).new

    spawn do
      socket = server.accept
      begin
        certificate = File.expand_path("../test/testcert.pem", __DIR__)
        proxy_context = OpenSSL::SSL::Context::Server.new
        proxy_context.certificate_chain = certificate
        proxy_context.private_key = certificate
        proxy_tls = OpenSSL::SSL::Socket::Server.new(socket, context: proxy_context, sync_close: false)
        connect = proxy_tls.gets("\r\n\r\n").not_nil!
        proxy_tls << "HTTP/1.1 200 Connection Established\r\n\r\n"
        proxy_tls.flush

        origin_context = OpenSSL::SSL::Context::Server.new
        origin_context.certificate_chain = certificate
        origin_context.private_key = certificate
        origin_tls = OpenSSL::SSL::Socket::Server.new(proxy_tls, context: origin_context, sync_close: false)
        request = origin_tls.gets("\r\n\r\n").not_nil!
        origin_tls << "HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\nnested-tls"
        origin_tls.flush
        observed.send({connect, request})
        origin_tls.close
        proxy_tls.close
      ensure
        socket.close
        done.send(nil)
      end
    end

    begin
      handler = CrDlp::Networking::CrystalHttpHandler.new(
        verify_tls: false,
        proxy: "https://127.0.0.1:#{address.port}",
      )
      response = handler.send(CrDlp::Networking::Request.new(
        "https://secure.example.test/video.mp4"
      ))
      connect, request = observed.receive

      response.text.should eq("nested-tls")
      connect.should contain("CONNECT secure.example.test HTTP/1.1")
      request.should contain("GET /video.mp4 HTTP/1.1")
      request.should contain("Host: secure.example.test")
    ensure
      done.receive
      server.close
    end
  end
end
