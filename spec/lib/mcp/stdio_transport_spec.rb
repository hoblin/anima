# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mcp::StdioTransport do
  # Simple MCP server that echoes back JSON-RPC responses for any request.
  def echo_server_script
    ["-e", <<~RUBY]
      require "json"
      $stdout.sync = true
      $stdin.each_line do |line|
        req = JSON.parse(line)
        response = {"jsonrpc" => "2.0", "id" => req["id"], "result" => {"tools" => []}}
        $stdout.puts(JSON.generate(response))
      end
    RUBY
  end

  # Server that sends a notification before the actual response.
  def notification_server_script
    ["-e", <<~RUBY]
      require "json"
      $stdout.sync = true
      $stdin.each_line do |line|
        req = JSON.parse(line)
        notification = {"jsonrpc" => "2.0", "method" => "notifications/progress"}
        $stdout.puts(JSON.generate(notification))
        response = {"jsonrpc" => "2.0", "id" => req["id"], "result" => {"ok" => true}}
        $stdout.puts(JSON.generate(response))
      end
    RUBY
  end

  # Server that exits after responding to one request.
  def single_response_server_script
    ["-e", <<~RUBY]
      require "json"
      $stdout.sync = true
      line = $stdin.gets
      req = JSON.parse(line)
      $stdout.puts(JSON.generate({"jsonrpc" => "2.0", "id" => req["id"], "result" => {}}))
      exit 0
    RUBY
  end

  # Server that writes non-JSON to stdout.
  def invalid_json_server_script
    ["-e", <<~RUBY]
      $stdout.sync = true
      $stdin.each_line { |_| $stdout.puts("this is not json") }
    RUBY
  end

  # Server that echoes back env vars as the result.
  def env_echo_server_script
    ["-e", <<~RUBY]
      require "json"
      $stdout.sync = true
      $stdin.each_line do |line|
        req = JSON.parse(line)
        $stdout.puts(JSON.generate({
          "jsonrpc" => "2.0",
          "id" => req["id"],
          "result" => {"test_var" => ENV["ANIMA_TEST_VAR"]}
        }))
      end
    RUBY
  end

  def json_rpc_request(method: "tools/list", id: SecureRandom.uuid)
    {jsonrpc: "2.0", id: id, method: method}
  end

  describe "#send_request" do
    context "with a working server" do
      subject(:transport) { described_class.new(command: "ruby", args: echo_server_script) }

      after { transport.shutdown }

      it "returns parsed JSON-RPC response" do
        result = transport.send_request(request: json_rpc_request)

        expect(result["result"]["tools"]).to eq([])
      end

      it "preserves the request id in the response" do
        request = json_rpc_request(id: "my-id-123")
        result = transport.send_request(request: request)

        expect(result["id"]).to eq("my-id-123")
      end

      it "spawns process lazily on first request" do
        allow(Open3).to receive(:popen2).and_call_original

        fresh = described_class.new(command: "ruby", args: echo_server_script)
        expect(Open3).not_to have_received(:popen2)

        fresh.send_request(request: json_rpc_request)
        expect(Open3).to have_received(:popen2).once
      ensure
        fresh&.shutdown
      end

      it "reuses process across multiple requests" do
        allow(Open3).to receive(:popen2).and_call_original

        transport.send_request(request: json_rpc_request)
        transport.send_request(request: json_rpc_request)

        expect(Open3).to have_received(:popen2).once
      end
    end

    context "with environment variables" do
      subject(:transport) do
        described_class.new(
          command: "ruby",
          args: env_echo_server_script,
          env: {"ANIMA_TEST_VAR" => "hello-from-test"}
        )
      end

      after { transport.shutdown }

      it "passes env vars to the child process" do
        result = transport.send_request(request: json_rpc_request)

        expect(result["result"]["test_var"]).to eq("hello-from-test")
      end
    end

    context "with server notifications" do
      subject(:transport) { described_class.new(command: "ruby", args: notification_server_script) }

      after { transport.shutdown }

      it "skips notifications and returns the matching response" do
        result = transport.send_request(request: json_rpc_request)

        expect(result["result"]["ok"]).to be true
      end
    end

    context "when server process crashes" do
      subject(:transport) { described_class.new(command: "ruby", args: single_response_server_script) }

      after { transport.shutdown }

      it "raises RequestHandlerError on the request that encounters the crash" do
        transport.send_request(request: json_rpc_request)

        expect {
          transport.send_request(request: json_rpc_request)
        }.to raise_error(MCP::Client::RequestHandlerError, /crashed/)
      end

      it "respawns process on the request after a crash" do
        transport.send_request(request: json_rpc_request)

        expect {
          transport.send_request(request: json_rpc_request)
        }.to raise_error(MCP::Client::RequestHandlerError)

        result = transport.send_request(request: json_rpc_request)
        expect(result["result"]).to eq({})
      end
    end

    context "when command is not found" do
      subject(:transport) { described_class.new(command: "anima-nonexistent-cmd-#{SecureRandom.hex(4)}") }

      it "raises RequestHandlerError" do
        expect {
          transport.send_request(request: json_rpc_request)
        }.to raise_error(MCP::Client::RequestHandlerError, /not found/)
      end
    end

    context "when server returns invalid JSON" do
      subject(:transport) { described_class.new(command: "ruby", args: invalid_json_server_script) }

      after { transport.shutdown }

      it "raises RequestHandlerError" do
        expect {
          transport.send_request(request: json_rpc_request)
        }.to raise_error(MCP::Client::RequestHandlerError, /Invalid JSON/)
      end
    end

    context "when server does not respond in time" do
      subject(:transport) { described_class.new(command: "ruby", args: ["-e", "sleep 999"]) }

      after { transport.shutdown }

      it "raises RequestHandlerError after timeout" do
        stub_const("Mcp::StdioTransport::RESPONSE_TIMEOUT", 0.5)

        expect {
          transport.send_request(request: json_rpc_request)
        }.to raise_error(MCP::Client::RequestHandlerError, /No response/)
      end
    end
  end

  describe "#shutdown" do
    subject(:transport) { described_class.new(command: "ruby", args: echo_server_script) }

    it "terminates the server process" do
      transport.send_request(request: json_rpc_request)
      transport.shutdown

      expect {
        transport.send_request(request: json_rpc_request)
      }.not_to raise_error
    end

    it "is safe to call multiple times" do
      transport.send_request(request: json_rpc_request)

      expect {
        transport.shutdown
        transport.shutdown
      }.not_to raise_error
    end

    it "is safe to call without having spawned a process" do
      expect { transport.shutdown }.not_to raise_error
    end
  end

  describe ".cleanup_all" do
    it "shuts down all tracked instances" do
      t1 = described_class.new(command: "ruby", args: echo_server_script)
      t2 = described_class.new(command: "ruby", args: echo_server_script)

      t1.send_request(request: json_rpc_request)
      t2.send_request(request: json_rpc_request)

      described_class.cleanup_all

      expect(t1.send(:alive?)).to be false
      expect(t2.send(:alive?)).to be false
    end
  end
end
