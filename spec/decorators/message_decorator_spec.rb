# frozen_string_literal: true

require "rails_helper"

RSpec.describe MessageDecorator, type: :decorator do
  subject(:decorator) { message.decorate }

  describe "Message#decorate" do
    context "with a user_message" do
      let(:message) { build_stubbed(:message, :user_message) }

      it "returns a UserMessageDecorator" do
        expect(decorator).to be_a(UserMessageDecorator)
      end
    end

    context "with an agent_message" do
      let(:message) { build_stubbed(:message, :agent_message) }

      it "returns an AgentMessageDecorator" do
        expect(decorator).to be_a(AgentMessageDecorator)
      end
    end

    context "with a system_message" do
      let(:message) { build_stubbed(:message, :system_message) }

      it "returns a SystemMessageDecorator" do
        expect(decorator).to be_a(SystemMessageDecorator)
      end
    end

    context "with a tool_call" do
      let(:message) { build_stubbed(:message, :bash_tool_call) }

      it "returns a ToolCallDecorator" do
        expect(decorator).to be_a(ToolCallDecorator)
      end
    end

    context "with a tool_response" do
      let(:message) { build_stubbed(:message, :bash_tool_response) }

      it "returns a ToolResponseDecorator" do
        expect(decorator).to be_a(ToolResponseDecorator)
      end
    end
  end

  describe "#render" do
    let(:message) { build_stubbed(:message, :user_message, payload: {"content" => "hi"}) }

    it "dispatches to render_basic for basic mode" do
      expect(decorator.render("basic")).to eq({role: :user, content: "hi"})
    end

    it "dispatches to render_verbose for verbose mode" do
      expect(decorator.render("verbose")).to include(role: :user, content: "hi")
    end

    it "dispatches to render_debug for debug mode" do
      result = decorator.render("debug")
      expect(result).to include(role: :user, content: "hi")
      expect(result).to have_key(:tokens)
    end

    it "dispatches to render_melete for melete mode" do
      expect(decorator.render("melete")).to eq("User: hi")
    end

    it "raises ArgumentError for an invalid mode" do
      expect { decorator.render("hacker_mode") }.to raise_error(ArgumentError, /Invalid view mode/)
    end

    it "raises ArgumentError for nil mode" do
      expect { decorator.render(nil) }.to raise_error(ArgumentError, /Invalid view mode/)
    end
  end

  describe "default view delegation" do
    let(:stub_decorator_class) do
      Class.new(described_class) do
        def render_basic
          {role: :stub, content: "stub output"}
        end
      end
    end
    let(:message) { build_stubbed(:message, :user_message) }
    let(:stub_decorator) { stub_decorator_class.new(message) }

    it "#render_verbose delegates to #render_basic" do
      expect(stub_decorator.render_verbose).to eq({role: :stub, content: "stub output"})
    end

    it "#render_debug delegates to #render_basic" do
      expect(stub_decorator.render_debug).to eq({role: :stub, content: "stub output"})
    end

    it "#render_melete returns nil" do
      nil_stub = Class.new(described_class) { def render_basic = nil }.new(message)
      expect(nil_stub.render_melete).to be_nil
    end
  end

  describe "#token_info (private)" do
    let(:message) { build_stubbed(:message, :user_message, token_count: 42) }

    it "returns the stored token count" do
      expect(decorator.send(:token_info)).to eq({tokens: 42})
    end
  end

  describe "#truncate_lines (private)" do
    let(:message) { build_stubbed(:message, :user_message) }

    it "returns text unchanged when under the limit" do
      expect(decorator.send(:truncate_lines, "line1\nline2", max_lines: 3)).to eq("line1\nline2")
    end

    it "returns text unchanged when exactly at the limit" do
      expect(decorator.send(:truncate_lines, "line1\nline2\nline3", max_lines: 3)).to eq("line1\nline2\nline3")
    end

    it "truncates and appends ellipsis when over the limit" do
      expect(decorator.send(:truncate_lines, "line1\nline2\nline3\nline4", max_lines: 2)).to eq("line1\nline2\n...")
    end

    it "handles nil text" do
      expect(decorator.send(:truncate_lines, nil, max_lines: 3)).to eq("")
    end

    it "handles empty text" do
      expect(decorator.send(:truncate_lines, "", max_lines: 3)).to eq("")
    end
  end

  describe "#truncate_middle (private)" do
    let(:message) { build_stubbed(:message, :user_message) }

    it "returns short text unchanged" do
      expect(decorator.send(:truncate_middle, "short text")).to eq("short text")
    end

    it "returns text unchanged when exactly at max_chars" do
      text = "x" * 500
      expect(decorator.send(:truncate_middle, text)).to eq(text)
    end

    it "truncates long text by cutting the middle" do
      text = "START#{"x" * 500}END"
      result = decorator.send(:truncate_middle, text, max_chars: 100)

      expect(result.length).to be <= 100
      expect(result).to start_with("START")
      expect(result).to end_with("END")
      expect(result).to include("[...truncated...]")
    end

    it "preserves both start and end of text" do
      text = "The user asked about OAuth config." + ("x" * 500) + "Final conclusion: config is wrong."
      result = decorator.send(:truncate_middle, text, max_chars: 200)

      expect(result).to include("The user asked about OAuth")
      expect(result).to include("config is wrong.")
    end

    it "handles nil text" do
      expect(decorator.send(:truncate_middle, nil)).to eq("")
    end

    it "handles empty text" do
      expect(decorator.send(:truncate_middle, "")).to eq("")
    end
  end
end
