# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::NicknameGenerator do
  let(:parent_session) { Session.create! }
  let(:task) { "Read lib/agent_loop.rb and summarize tool flow" }

  describe ".call" do
    it "generates a nickname via fast LLM call", :vcr do
      nickname = described_class.call(task, parent_session)

      expect(nickname).to be_a(String)
      expect(nickname).not_to be_empty
      expect(nickname).to match(/\A[\w-]+\z/)
    end

    it "returns a sanitized lowercase nickname" do
      client = instance_double(LLM::Client, chat: "  Loop-Sleuth!  ")
      allow(LLM::Client).to receive(:new).and_return(client)

      nickname = described_class.call(task, parent_session)
      expect(nickname).to eq("loop-sleuth")
    end

    it "appends numeric suffix on collision" do
      Session.create!(parent_session: parent_session, prompt: "sub", name: "loop-sleuth")

      client = instance_double(LLM::Client, chat: "loop-sleuth")
      allow(LLM::Client).to receive(:new).and_return(client)

      nickname = described_class.call(task, parent_session)
      expect(nickname).to eq("loop-sleuth-2")
    end

    it "increments suffix past existing collisions" do
      Session.create!(parent_session: parent_session, prompt: "sub", name: "loop-sleuth")
      Session.create!(parent_session: parent_session, prompt: "sub", name: "loop-sleuth-2")

      client = instance_double(LLM::Client, chat: "loop-sleuth")
      allow(LLM::Client).to receive(:new).and_return(client)

      nickname = described_class.call(task, parent_session)
      expect(nickname).to eq("loop-sleuth-3")
    end

    it "falls back to agent-N on LLM failure" do
      allow(LLM::Client).to receive(:new).and_raise(StandardError, "API down")

      nickname = described_class.call(task, parent_session)
      expect(nickname).to match(/\Aagent-\d+\z/)
    end

    it "truncates long nicknames to 50 characters" do
      long_name = "a" * 100
      client = instance_double(LLM::Client, chat: long_name)
      allow(LLM::Client).to receive(:new).and_return(client)

      nickname = described_class.call(task, parent_session)
      expect(nickname.length).to be <= 50
    end
  end
end
