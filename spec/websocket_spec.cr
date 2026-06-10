require "./spec_helper"
require "http/server"
require "http/web_socket"

private class RejectWebSocketHandler
  include HTTP::Handler

  def call(context) : Nil
    if context.request.path == "/reject"
      context.response.status = HTTP::Status::BAD_REQUEST
      context.response.print("rejected")
    else
      call_next(context)
    end
  end
end

private class WebSocketHandshakeHeaders
  include HTTP::Handler

  def call(context) : Nil
    context.response.headers["X-Handshake"] = "accepted"
    context.response.headers["Set-Cookie"] = "from_ws=stored; Path=/"
    call_next(context)
  end
end

private class WebSocketProcessRunner < CrDlp::ProcessRunner
  getter streamed = Bytes.empty
  getter command : String?
  getter arguments = [] of String

  def initialize(@available = true, @succeeds = true)
  end

  def executable_available?(command : String) : Bool
    @available
  end

  def run(command : String, arguments : Array(String)) : CrDlp::ProcessResult
    CrDlp::ProcessResult.new(0, "", "")
  end

  def run_with_input(
    command : String,
    arguments : Array(String),
    &writer : IO ->
  ) : CrDlp::ProcessResult
    @command = command
    @arguments = arguments
    input = IO::Memory.new
    writer.call(input)
    @streamed = input.to_slice.dup
    if @succeeds
      File.write(arguments.last, @streamed)
      CrDlp::ProcessResult.new(0, "", "")
    else
      CrDlp::ProcessResult.new(1, "", "fixture failure")
    end
  end
end

private def ws_read(io : IO, count : Int) : Bytes
  bytes = Bytes.new(count)
  io.read_fully(bytes)
  bytes
end

private def with_websocket_server(tls = false, &block : String ->)
  websocket = HTTP::WebSocketHandler.new(["chat", "json"]) do |socket, context|
    if context.request.path == "/stream"
      spawn do
        sleep 1.millisecond
        socket.send(Bytes[0x41])
        socket.send("B")
        socket.send(Bytes[0x43])
        socket.close
      end
    end
    socket.on_message do |message|
      case message
      when "headers"
        values = Hash(String, String).new
        context.request.headers.each { |name, entries| values[name] = entries.join(", ") }
        socket.send(values.to_json)
      when "path"
        socket.send(context.request.resource)
      when "large"
        socket.send("0123456789" * 10_000)
      when "ping"
        socket.ping("heartbeat")
        socket.send("after-ping")
      when "close"
        socket.close
      else
        socket.send(message)
      end
    end
    socket.on_binary { |message| socket.send(message) }
  end

  handlers = [
    RejectWebSocketHandler.new,
    WebSocketHandshakeHeaders.new,
    websocket,
  ] of HTTP::Handler
  server = HTTP::Server.new(handlers) do |context|
    context.response.status = HTTP::Status::NOT_FOUND
  end
  address = if tls
              context = OpenSSL::SSL::Context::Server.new
              certificate = File.expand_path("../test/testcert.pem", __DIR__)
              context.certificate_chain = certificate
              context.private_key = certificate
              server.bind_tls("127.0.0.1", 0, context)
            else
              server.bind_tcp("127.0.0.1", 0)
            end
  spawn { server.listen }
  sleep 1.millisecond
  begin
    yield "#{tls ? "wss" : "ws"}://127.0.0.1:#{address.port}"
  ensure
    server.close
  end
end

private def with_socks5_relay(&block : String, Channel(Tuple(String, Int32)) ->)
  server = TCPServer.new("127.0.0.1", 0)
  address = server.local_address.as(Socket::IPAddress)
  observed = Channel(Tuple(String, Int32)).new(1)
  done = Channel(Nil).new(1)

  spawn do
    client = server.accept
    upstream = nil.as(TCPSocket?)
    begin
      greeting = ws_read(client, 2)
      ws_read(client, greeting[1])
      client.write(Bytes[5, 0])
      client.flush

      request = ws_read(client, 4)
      host = case request[3]
             when 1
               ws_read(client, 4).join(".")
             when 3
               String.new(ws_read(client, ws_read(client, 1)[0]))
             else
               raise "Unsupported test SOCKS address type"
             end
      port_bytes = ws_read(client, 2)
      port = (port_bytes[0].to_i << 8) | port_bytes[1]
      upstream = TCPSocket.new(host, port)
      client.write(Bytes[5, 0, 0, 1, 127, 0, 0, 1, 0, 0])
      client.flush
      observed.send({host, port})

      copied = Channel(Nil).new(2)
      spawn do
        IO.copy(client, upstream)
      rescue
      ensure
        upstream.close
        copied.send(nil)
      end
      spawn do
        IO.copy(upstream, client)
      rescue
      ensure
        client.close
        copied.send(nil)
      end
      2.times { copied.receive }
    ensure
      upstream.try(&.close)
      client.close
      done.send(nil)
    end
  end

  begin
    yield "socks5h://127.0.0.1:#{address.port}", observed
  ensure
    done.receive
    server.close
  end
end

describe CrDlp::Networking::CrystalWebSocketHandler do
  it "performs a compliant handshake and exchanges text and binary frames" do
    with_websocket_server do |base_url|
      handler = CrDlp::Networking::CrystalWebSocketHandler.new(proxy: "")
      response = handler.send(
        CrDlp::Networking::Request.new(
          base_url,
          headers: {"Sec-WebSocket-Protocol" => "json, chat"},
        )
      ).as(CrDlp::Networking::WebSocketResponse)

      response.status.should eq(101)
      response.headers["Upgrade"].downcase.should eq("websocket")
      response.headers["X-Handshake"].should eq("accepted")
      response.protocol.should eq("json")
      response.success?.should be_true

      response.send("hello")
      response.recv.should eq("hello")
      response.send(Bytes[0, 1, 2, 0xff])
      response.recv.should eq(Bytes[0, 1, 2, 0xff])
      response.close
      response.closed?.should be_true
    end
  end

  it "merges default and request headers and synchronizes handshake cookies" do
    with_websocket_server do |base_url|
      jar = CrDlp::CookieJar.new
      jar.add(CrDlp::CookieJar::Cookie.new(
        "127.0.0.1",
        false,
        "/",
        false,
        nil,
        "session",
        "fixture",
      ))
      handler = CrDlp::Networking::CrystalWebSocketHandler.new(
        default_headers: {"X-Default" => "one", "User-Agent" => "cr-dlp-test"},
        cookie_jar: jar,
        proxy: "",
      )
      response = handler.send(CrDlp::Networking::Request.new(
        base_url,
        headers: {"X-Default" => "changed", "X-Request" => "two"},
      )).as(CrDlp::Networking::WebSocketResponse)

      response.send("headers")
      headers = JSON.parse(response.recv.as(String)).as_h
      headers["X-Default"].as_s.should eq("changed")
      headers["X-Request"].as_s.should eq("two")
      headers["User-Agent"].as_s.should eq("cr-dlp-test")
      headers["Cookie"].as_s.should eq("session=fixture")
      response.close

      jar.header_for("#{base_url}/next").not_nil!.should contain("from_ws=stored")
    end
  end

  it "handles large frames, ping frames, normalized paths, and preserved escapes" do
    with_websocket_server do |base_url|
      handler = CrDlp::Networking::CrystalWebSocketHandler.new(proxy: "")
      response = handler.send(CrDlp::Networking::Request.new("#{base_url}/a/b/./../../%c7%9f"))
        .as(CrDlp::Networking::WebSocketResponse)

      response.send("path")
      response.recv.should eq("/%c7%9f")
      response.send("large")
      response.recv.should eq("0123456789" * 10_000)
      response.send("ping")
      response.recv.should eq("after-ping")
      response.close
    end
  end

  it "percent-encodes Unicode request paths" do
    with_websocket_server do |base_url|
      response = CrDlp::Networking::CrystalWebSocketHandler.new(proxy: "").send(
        CrDlp::Networking::Request.new("#{base_url}/中文")
      ).as(CrDlp::Networking::WebSocketResponse)
      response.send("path")
      response.recv.should eq("/%E4%B8%AD%E6%96%87")
      response.close
    end
  end

  it "surfaces handshake status and closed-connection failures" do
    with_websocket_server do |base_url|
      handler = CrDlp::Networking::CrystalWebSocketHandler.new(proxy: "")
      error = expect_raises(CrDlp::HttpError) do
        handler.send(CrDlp::Networking::Request.new("#{base_url}/reject"))
      end
      error.status.should eq(400)

      response = handler.send(CrDlp::Networking::Request.new(base_url))
        .as(CrDlp::Networking::WebSocketResponse)
      response.send("close")
      expect_raises(CrDlp::RequestError, "closed") { response.recv }
      expect_raises(CrDlp::RequestError, "closed") { response.send("late") }
    end
  end

  it "rejects invalid methods, HTTP proxies, probes, and downloads" do
    with_websocket_server do |base_url|
      handler = CrDlp::Networking::CrystalWebSocketHandler.new(proxy: "")
      expect_raises(CrDlp::UnsupportedRequest, "must use GET") do
        handler.send(CrDlp::Networking::Request.new(base_url, method: "POST"))
      end
      expect_raises(CrDlp::UnsupportedRequest, "cannot be probed") do
        handler.probe(CrDlp::Networking::Request.new(base_url))
      end
      expect_raises(CrDlp::UnsupportedRequest, "cannot be used") do
        handler.download(CrDlp::Networking::Request.new(base_url), IO::Memory.new)
      end
      expect_raises(CrDlp::UnsupportedRequest, "only supports SOCKS") do
        CrDlp::Networking::CrystalWebSocketHandler.new(proxy: "http://127.0.0.1:9")
          .send(CrDlp::Networking::Request.new(base_url))
      end
    end
  end

  it "is available through the request director and default client" do
    with_websocket_server do |base_url|
      director = CrDlp::Networking::RequestDirector.new([
        CrDlp::Networking::CrystalWebSocketHandler.new(proxy: ""),
      ] of CrDlp::Networking::RequestHandler)
      response = director.open_websocket(CrDlp::Networking::Request.new(base_url))
      response.send("director")
      response.recv.should eq("director")
      response.close

      client = CrDlp::Client.new(CrDlp::ParsedOptions.new({
        "proxy" => JSON::Any.new(""),
      }))
      client.request_director.handlers.any? do |handler|
        handler.is_a?(CrDlp::Networking::CrystalWebSocketHandler)
      end.should be_true
      client.downloader_registry.build("websocket_frag", client)
        .should be_a(CrDlp::WebSocketFragmentDownloader)
    end
  end

  it "connects through a SOCKS5 proxy with remote DNS" do
    with_websocket_server do |base_url|
      target = URI.parse(base_url)
      proxied_url = "ws://localhost:#{target.port}/proxied"
      with_socks5_relay do |proxy_url, observed|
        response = CrDlp::Networking::CrystalWebSocketHandler.new(proxy: proxy_url)
          .send(CrDlp::Networking::Request.new(proxied_url))
          .as(CrDlp::Networking::WebSocketResponse)
        response.send("proxy")
        response.recv.should eq("proxy")
        response.close

        host, port = observed.receive
        host.should eq("localhost")
        port.should eq(target.port)
      end
    end
  end

  it "supports WSS with configurable certificate verification" do
    with_websocket_server(tls: true) do |base_url|
      expect_raises(CrDlp::RequestError) do
        CrDlp::Networking::CrystalWebSocketHandler.new(proxy: "")
          .send(CrDlp::Networking::Request.new(base_url))
      end

      response = CrDlp::Networking::CrystalWebSocketHandler.new(
        verify_tls: false,
        proxy: "",
      ).send(CrDlp::Networking::Request.new(base_url))
        .as(CrDlp::Networking::WebSocketResponse)
      response.send("secure")
      response.recv.should eq("secure")
      response.close
    end
  end
end

describe CrDlp::WebSocketFragmentDownloader do
  it "streams text and binary fragments through ffmpeg stdin" do
    with_websocket_server do |base_url|
      directory = File.join(Dir.tempdir, "cr-dlp-ws-#{Random::Secure.hex(6)}")
      Dir.mkdir(directory)
      begin
        runner = WebSocketProcessRunner.new
        director = CrDlp::Networking::RequestDirector.new([
          CrDlp::Networking::CrystalWebSocketHandler.new(proxy: ""),
        ] of CrDlp::Networking::RequestHandler)
        client = CrDlp::Client.new(
          CrDlp::ParsedOptions.new({
            "fixup" => JSON::Any.new("never"),
          }),
          request_director: director,
          process_runner: runner,
          auto_init: false,
        )
        events = [] of Hash(String, JSON::Any)
        client.add_progress_hook { |event| events << event }
        info = CrDlp::Info.new({
          "id"       => JSON::Any.new("stream"),
          "title"    => JSON::Any.new("stream"),
          "url"      => JSON::Any.new("#{base_url}/stream"),
          "protocol" => JSON::Any.new("websocket_frag"),
          "ext"      => JSON::Any.new("mp4"),
        })
        filename = File.join(directory, "stream.mp4")

        CrDlp::WebSocketFragmentDownloader.new(client).download(info, filename)

        File.read(filename).should eq("ABC")
        runner.streamed.should eq("ABC".to_slice)
        runner.command.should eq("ffmpeg")
        runner.arguments.should contain("pipe:0")
        runner.arguments.should contain("mp4")
        runner.arguments.last.should end_with(".part.mp4")
        events.first["status"].as_s.should eq("downloading")
        events.last["status"].as_s.should eq("finished")
        events.last["downloaded_bytes"].as_i64.should eq(3)
      ensure
        FileUtils.rm_rf(directory)
      end
    end
  end

  it "reports unavailable and failed ffmpeg streaming" do
    info = CrDlp::Info.new({
      "id"       => JSON::Any.new("stream"),
      "title"    => JSON::Any.new("stream"),
      "url"      => JSON::Any.new("ws://127.0.0.1:1/stream"),
      "protocol" => JSON::Any.new("websocket_frag"),
      "ext"      => JSON::Any.new("mp4"),
    })
    unavailable = CrDlp::Client.new(
      process_runner: WebSocketProcessRunner.new(available: false),
      auto_init: false,
    )
    expect_raises(CrDlp::DownloadError, "ffmpeg is required") do
      CrDlp::WebSocketFragmentDownloader.new(unavailable).download(info, "unused.mp4")
    end

    with_websocket_server do |base_url|
      info["url"] = "#{base_url}/stream"
      runner = WebSocketProcessRunner.new(succeeds: false)
      director = CrDlp::Networking::RequestDirector.new([
        CrDlp::Networking::CrystalWebSocketHandler.new(proxy: ""),
      ] of CrDlp::Networking::RequestHandler)
      client = CrDlp::Client.new(
        request_director: director,
        process_runner: runner,
        auto_init: false,
      )
      expect_raises(CrDlp::DownloadError, "fixture failure") do
        CrDlp::WebSocketFragmentDownloader.new(client).download(info, "unused.mp4")
      end
    ensure
      File.delete?("unused.mp4")
      File.delete?("unused.part.mp4")
    end
  end
end
