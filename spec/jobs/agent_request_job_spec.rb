# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRequestJob do
  let(:session) { Session.create! }
  let(:valid_token) { "sk-ant-oat01-#{"a" * 68}" }

  before do
    allow(Rails.application.credentials).to receive(:dig)
      .with(:anthropic, :subscription_token)
      .and_return(valid_token)
    allow(Mcp::ClientManager).to receive(:new)
      .and_return(instance_double(Mcp::ClientManager, register_tools: []))
  end

  describe "retry configuration" do
    it "retries on TransientError" do
      expect(described_class.rescue_handlers).to include(
        satisfy { |handler| handler[0] == "Providers::Anthropic::TransientError" }
      )
    end

    it "discards on AuthenticationError" do
      expect(described_class.rescue_handlers).to include(
        satisfy { |handler| handler[0] == "Providers::Anthropic::AuthenticationError" }
      )
    end

    it "discards on RecordNotFound" do
      expect(described_class.rescue_handlers).to include(
        satisfy { |handler| handler[0] == "ActiveRecord::RecordNotFound" }
      )
    end
  end

  describe "#perform" do
    it "runs the agent loop for the given session" do
      session.events.create!(
        event_type: "user_message",
        payload: {"content" => "Hello"},
        timestamp: 1
      )

      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 200,
          body: {
            content: [{type: "text", text: "Hi there!"}],
            stop_reason: "end_turn"
          }.to_json,
          headers: {"content-type" => "application/json"}
        )

      collector = Events::Subscribers::MessageCollector.new
      Events::Bus.subscribe(collector)

      described_class.perform_now(session.id)

      expect(collector.messages.last).to eq({role: "assistant", content: "Hi there!"})
      Events::Bus.unsubscribe(collector)
    end

    it "sets processing flag during execution" do
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      processing_during_run = nil
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return do
          processing_during_run = session.reload.processing?
          {status: 200,
           body: {content: [{type: "text", text: "ok"}], stop_reason: "end_turn"}.to_json,
           headers: {"content-type" => "application/json"}}
        end

      described_class.perform_now(session.id)

      expect(processing_during_run).to be true
      expect(session.reload.processing?).to be false
    end

    it "skips execution when session is already processing" do
      session.update!(processing: true)
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      # Should not make any API calls
      described_class.perform_now(session.id)

      expect(session.reload.processing?).to be false
    end

    it "promotes pending messages and re-runs after agent loop" do
      session.events.create!(event_type: "user_message", payload: {"content" => "first"}, timestamp: 1)

      call_count = 0
      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return do
          call_count += 1
          if call_count == 1
            # Simulate a pending message arriving during first processing
            session.events.create!(
              event_type: "user_message",
              payload: {"content" => "second", "status" => "pending"},
              timestamp: 2,
              status: "pending"
            )
          end
          {status: 200,
           body: {content: [{type: "text", text: "response #{call_count}"}], stop_reason: "end_turn"}.to_json,
           headers: {"content-type" => "application/json"}}
        end

      described_class.perform_now(session.id)

      expect(call_count).to eq(2)
      expect(session.events.where(status: "pending").count).to eq(0)
    end

    it "schedules analytical brain after the agent loop completes" do
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)
      # Pre-create agent reply since the test env doesn't persist via event bus
      session.events.create!(event_type: "agent_message", payload: {"content" => "Hi!"}, timestamp: 2)

      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 200,
          body: {content: [{type: "text", text: "Hi!"}], stop_reason: "end_turn"}.to_json,
          headers: {"content-type" => "application/json"}
        )

      expect { described_class.perform_now(session.id) }
        .to have_enqueued_job(AnalyticalBrainJob).with(session.id)
    end

    it "finalizes the agent loop after completion" do
      session.events.create!(
        event_type: "user_message",
        payload: {"content" => "Hello"},
        timestamp: 1
      )

      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 200,
          body: {
            content: [{type: "text", text: "done"}],
            stop_reason: "end_turn"
          }.to_json,
          headers: {"content-type" => "application/json"}
        )

      # Should not raise — finalize cleans up ShellSession
      expect { described_class.perform_now(session.id) }.not_to raise_error
    end

    it "finalizes the agent loop even on error" do
      session.events.create!(
        event_type: "user_message",
        payload: {"content" => "Hello"},
        timestamp: 1
      )

      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 401, body: {error: {message: "unauthorized"}}.to_json,
          headers: {"content-type" => "application/json"})

      # discard_on prevents the error from propagating
      expect { described_class.perform_now(session.id) }.not_to raise_error
    end

    it "clears processing flag even on error" do
      session.events.create!(event_type: "user_message", payload: {"content" => "Hello"}, timestamp: 1)

      stub_request(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 401, body: {error: {message: "unauthorized"}}.to_json,
          headers: {"content-type" => "application/json"})

      described_class.perform_now(session.id)

      expect(session.reload.processing?).to be false
    end
  end

  describe "transient error handling" do
    before do
      session.events.create!(
        event_type: "user_message",
        payload: {"content" => "Hello"},
        timestamp: 1
      )
    end

    context "connection reset (network failure)" do
      it "emits a system message with retry notification" do
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_raise(Errno::ECONNRESET.new("Connection reset by peer"))

        emitted_events = []
        allow(Events::Bus).to receive(:emit).and_wrap_original do |method, event|
          emitted_events << event
          method.call(event)
        end

        perform_enqueued_jobs { described_class.perform_later(session.id) }

        system_messages = emitted_events.select { |e| e.is_a?(Events::SystemMessage) }
        expect(system_messages).not_to be_empty
        expect(system_messages.first.to_h[:content]).to include("retrying")
      end

      it "emits failure message after all retries are exhausted" do
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_raise(Errno::ECONNRESET.new("Connection reset by peer"))

        emitted_events = []
        allow(Events::Bus).to receive(:emit).and_wrap_original do |method, event|
          emitted_events << event
          method.call(event)
        end

        perform_enqueued_jobs { described_class.perform_later(session.id) }

        system_messages = emitted_events.select { |e| e.is_a?(Events::SystemMessage) }
        expect(system_messages.last.to_h[:content]).to include("Failed after multiple retries")
      end
    end

    context "rate limit (HTTP 429)" do
      it "retries with exponential backoff" do
        call_count = 0
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return do
            call_count += 1
            if call_count < 3
              {status: 429, body: {error: {message: "rate limited"}}.to_json,
               headers: {"content-type" => "application/json"}}
            else
              {status: 200,
               body: {content: [{type: "text", text: "Success!"}], stop_reason: "end_turn"}.to_json,
               headers: {"content-type" => "application/json"}}
            end
          end

        collector = Events::Subscribers::MessageCollector.new
        Events::Bus.subscribe(collector)

        perform_enqueued_jobs { described_class.perform_later(session.id) }

        expect(collector.messages.last).to eq({role: "assistant", content: "Success!"})
        expect(call_count).to eq(3)
        Events::Bus.unsubscribe(collector)
      end
    end

    context "server error (HTTP 5xx)" do
      it "retries on 500 server error" do
        call_count = 0
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return do
            call_count += 1
            if call_count < 2
              {status: 500, body: "Internal Server Error"}
            else
              {status: 200,
               body: {content: [{type: "text", text: "Recovered!"}], stop_reason: "end_turn"}.to_json,
               headers: {"content-type" => "application/json"}}
            end
          end

        collector = Events::Subscribers::MessageCollector.new
        Events::Bus.subscribe(collector)

        perform_enqueued_jobs { described_class.perform_later(session.id) }

        expect(collector.messages.last).to eq({role: "assistant", content: "Recovered!"})
        Events::Bus.unsubscribe(collector)
      end

      it "retries on 502 bad gateway" do
        call_count = 0
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return do
            call_count += 1
            if call_count < 2
              {status: 502, body: "Bad Gateway"}
            else
              {status: 200,
               body: {content: [{type: "text", text: "OK"}], stop_reason: "end_turn"}.to_json,
               headers: {"content-type" => "application/json"}}
            end
          end

        collector = Events::Subscribers::MessageCollector.new
        Events::Bus.subscribe(collector)

        perform_enqueued_jobs { described_class.perform_later(session.id) }

        expect(collector.messages.last).to eq({role: "assistant", content: "OK"})
        Events::Bus.unsubscribe(collector)
      end

      it "retries on 503 service unavailable" do
        call_count = 0
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return do
            call_count += 1
            if call_count < 2
              {status: 503, body: "Service Unavailable"}
            else
              {status: 200,
               body: {content: [{type: "text", text: "Back!"}], stop_reason: "end_turn"}.to_json,
               headers: {"content-type" => "application/json"}}
            end
          end

        collector = Events::Subscribers::MessageCollector.new
        Events::Bus.subscribe(collector)

        perform_enqueued_jobs { described_class.perform_later(session.id) }

        expect(collector.messages.last).to eq({role: "assistant", content: "Back!"})
        Events::Bus.unsubscribe(collector)
      end
    end

    context "timeout" do
      it "retries on Net::ReadTimeout" do
        call_count = 0
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return do
            call_count += 1
            if call_count < 2
              raise Net::ReadTimeout, "Net::ReadTimeout"
            else
              {status: 200,
               body: {content: [{type: "text", text: "Done!"}], stop_reason: "end_turn"}.to_json,
               headers: {"content-type" => "application/json"}}
            end
          end

        collector = Events::Subscribers::MessageCollector.new
        Events::Bus.subscribe(collector)

        perform_enqueued_jobs { described_class.perform_later(session.id) }

        expect(collector.messages.last).to eq({role: "assistant", content: "Done!"})
        Events::Bus.unsubscribe(collector)
      end
    end

    context "DNS failure" do
      it "retries on SocketError" do
        call_count = 0
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return do
            call_count += 1
            if call_count < 2
              raise SocketError, "getaddrinfo: Name or service not known"
            else
              {status: 200,
               body: {content: [{type: "text", text: "Resolved!"}], stop_reason: "end_turn"}.to_json,
               headers: {"content-type" => "application/json"}}
            end
          end

        collector = Events::Subscribers::MessageCollector.new
        Events::Bus.subscribe(collector)

        perform_enqueued_jobs { described_class.perform_later(session.id) }

        expect(collector.messages.last).to eq({role: "assistant", content: "Resolved!"})
        Events::Bus.unsubscribe(collector)
      end
    end
  end

  describe "non-transient error handling" do
    before do
      session.events.create!(
        event_type: "user_message",
        payload: {"content" => "Hello"},
        timestamp: 1
      )
    end

    context "authentication failure (HTTP 401)" do
      before do
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return(
            status: 401,
            body: {error: {message: "invalid api key"}}.to_json,
            headers: {"content-type" => "application/json"}
          )
      end

      it "fails immediately without retrying" do
        emitted_events = []
        allow(Events::Bus).to receive(:emit).and_wrap_original do |method, event|
          emitted_events << event
          method.call(event)
        end

        described_class.perform_now(session.id)

        system_messages = emitted_events.select { |e| e.is_a?(Events::SystemMessage) }
        expect(system_messages.last.to_h[:content]).to include("Authentication failed")
      end

      it "broadcasts authentication_required signal via ActionCable" do
        expect {
          described_class.perform_now(session.id)
        }.to have_broadcasted_to("session_#{session.id}")
          .with(a_hash_including("action" => "authentication_required"))
      end
    end

    context "deleted session" do
      it "discards without retrying when session does not exist" do
        expect {
          described_class.perform_now(-1)
        }.not_to raise_error
      end
    end

    context "bad request (HTTP 400)" do
      it "does not retry and raises the error" do
        stub_request(:post, "https://api.anthropic.com/v1/messages")
          .to_return(
            status: 400,
            body: {error: {message: "invalid model"}}.to_json,
            headers: {"content-type" => "application/json"}
          )

        expect {
          described_class.perform_now(session.id)
        }.to raise_error(Providers::Anthropic::Error, /Bad request/)
      end
    end
  end
end
