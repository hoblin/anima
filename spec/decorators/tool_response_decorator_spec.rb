# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolResponseDecorator, type: :decorator do
  subject(:decorator) { message.decorate }

  describe "#render_basic" do
    context "for a regular tool response" do
      let(:message) do
        build_stubbed(:message, :tool_response,
          payload: {"content" => "file.txt", "tool_name" => "bash", "success" => true})
      end

      it "returns nil (hidden in basic mode)" do
        expect(decorator.render_basic).to be_nil
      end
    end

    context "for a think tool response" do
      let(:message) do
        build_stubbed(:message, :tool_response,
          payload: {"content" => "OK", "tool_name" => "think", "success" => true})
      end

      it "returns nil" do
        expect(decorator.render_basic).to be_nil
      end
    end
  end

  describe "#render_verbose" do
    context "with successful output" do
      let(:message) do
        build_stubbed(:message, :tool_response,
          payload: {"content" => "file.txt", "tool_name" => "bash", "success" => true},
          timestamp: 1)
      end

      it "returns a structured hash with success true" do
        expect(decorator.render_verbose).to eq({
          role: :tool_response, tool: "bash", content: "file.txt", success: true, timestamp: 1
        })
      end
    end

    context "with failed output" do
      let(:message) do
        build_stubbed(:message, :tool_response,
          payload: {"content" => "command not found", "tool_name" => "bash", "success" => false},
          timestamp: 1)
      end

      it "returns a structured hash with success false" do
        expect(decorator.render_verbose).to eq({
          role: :tool_response, tool: "bash", content: "command not found", success: false, timestamp: 1
        })
      end
    end

    context "with output exceeding 3 lines" do
      let(:long_output) { "line1\nline2\nline3\nline4\nline5" }
      let(:message) do
        build_stubbed(:message, :tool_response,
          payload: {"content" => long_output, "tool_name" => "bash", "success" => true},
          timestamp: 1)
      end

      it "truncates after the third line" do
        expect(decorator.render_verbose[:content]).to eq("line1\nline2\nline3\n...")
      end
    end

    context "with multiline output within the limit" do
      let(:output) { "line1\nline2\nline3" }
      let(:message) do
        build_stubbed(:message, :tool_response,
          payload: {"content" => output, "tool_name" => "bash", "success" => true},
          timestamp: 1)
      end

      it "preserves all lines" do
        expect(decorator.render_verbose[:content]).to eq(output)
      end
    end

    context "with nil content" do
      let(:message) do
        build_stubbed(:message, :tool_response,
          payload: {"content" => nil, "tool_name" => "bash", "success" => true},
          timestamp: 1)
      end

      it "coerces to an empty string" do
        expect(decorator.render_verbose[:content]).to eq("")
      end
    end

    context "with empty content" do
      let(:message) do
        build_stubbed(:message, :tool_response,
          payload: {"content" => "", "tool_name" => "bash", "success" => true},
          timestamp: 1)
      end

      it "renders an empty content field" do
        expect(decorator.render_verbose[:content]).to eq("")
      end
    end

    context "when success is missing from payload" do
      let(:message) do
        build_stubbed(:message, :tool_response,
          payload: {"content" => "output", "tool_name" => "bash"},
          timestamp: 1)
      end

      it "defaults success to true" do
        expect(decorator.render_verbose[:success]).to be true
      end
    end

    context "for a think tool response" do
      let(:message) do
        build_stubbed(:message, :tool_response,
          payload: {"content" => "OK", "tool_name" => "think", "success" => true},
          timestamp: 1)
      end

      it "returns nil for noise suppression" do
        expect(decorator.render_verbose).to be_nil
      end
    end
  end

  describe "#render_debug" do
    context "with long output" do
      let(:long_output) { "line1\nline2\nline3\nline4\nline5" }
      let(:message) do
        build_stubbed(:message, :tool_response,
          payload: {"content" => long_output, "tool_name" => "bash", "success" => true, "tool_use_id" => "toolu_01abc123"},
          tool_use_id: "toolu_01abc123",
          timestamp: 1)
      end

      it "returns full untruncated content" do
        result = decorator.render_debug
        expect(result[:content]).to eq(long_output)
        expect(result[:content]).not_to include("...")
      end
    end

    context "with a tool_use_id" do
      let(:message) do
        build_stubbed(:message, :tool_response,
          payload: {"content" => "output", "tool_name" => "bash", "success" => true, "tool_use_id" => "toolu_xyz"},
          tool_use_id: "toolu_xyz",
          timestamp: 1)
      end

      it "includes the tool_use_id and success flag" do
        result = decorator.render_debug
        expect(result[:tool_use_id]).to eq("toolu_xyz")
        expect(result[:success]).to be true
      end
    end

    context "with a failed response" do
      let(:message) do
        build_stubbed(:message, :tool_response,
          payload: {"content" => "command not found", "tool_name" => "bash", "success" => false, "tool_use_id" => "toolu_fail"},
          tool_use_id: "toolu_fail",
          timestamp: 1)
      end

      it "shows failure status" do
        expect(decorator.render_debug[:success]).to be false
      end
    end

    context "for a think tool response" do
      let(:message) do
        build_stubbed(:message, :tool_response,
          payload: {"content" => "OK", "tool_name" => "think", "success" => true, "tool_use_id" => "toolu_think_r1"},
          tool_use_id: "toolu_think_r1",
          timestamp: 1)
      end

      it "shows the response in debug mode for completeness" do
        result = decorator.render_debug
        expect(result[:role]).to eq(:tool_response)
        expect(result[:content]).to eq("OK")
        expect(result[:tool_use_id]).to eq("toolu_think_r1")
      end
    end
  end

  describe "#render_brain" do
    context "with a successful tool response" do
      let(:message) do
        build_stubbed(:message, :tool_response,
          payload: {"content" => "file1.rb\nfile2.rb", "tool_name" => "bash", "success" => true})
      end

      it "returns the success emoji" do
        expect(decorator.render_brain).to eq("\u2705")
      end
    end

    context "with a failed tool response" do
      let(:message) do
        build_stubbed(:message, :tool_response,
          payload: {"content" => "command not found", "tool_name" => "bash", "success" => false})
      end

      it "returns the failure emoji" do
        expect(decorator.render_brain).to eq("\u274C")
      end
    end

    context "for a think tool response" do
      let(:message) do
        build_stubbed(:message, :tool_response,
          payload: {"content" => "OK", "tool_name" => "think", "success" => true})
      end

      it "returns nil" do
        expect(decorator.render_brain).to be_nil
      end
    end

    context "when success is missing from payload" do
      let(:message) do
        build_stubbed(:message, :tool_response,
          payload: {"content" => "output", "tool_name" => "bash"})
      end

      it "defaults to the success emoji" do
        expect(decorator.render_brain).to eq("\u2705")
      end
    end
  end
end
