# frozen_string_literal: true

require "rails_helper"

RSpec.describe PendingMessageDecorator do
  let(:session) { create(:session) }

  describe "#render('melete')" do
    # Factory default already produces a user_message PM; other rows use traits.
    {
      [nil, {}] => "User (pending): write me a gh ticket",
      [:subagent, {source_name: "scout"}] => "Sub-agent scout (pending): write me a gh ticket",
      [:tool_response, {tool_use_id: "toolu_abc"}] => "tool_response toolu_abc (pending): write me a gh ticket",
      [:from_mneme, {}] => "Mneme recalled (pending): write me a gh ticket",
      [:from_melete_skill, {source_name: "gh-issue"}] => "Melete activated skill: gh-issue",
      [:from_melete_workflow, {source_name: "feature"}] => "Melete activated workflow: feature",
      [:from_melete_goal, {source_name: "42"}] => "Melete logged goal 42: write me a gh ticket"
    }.each do |(trait, overrides), expected_line|
      context "with trait #{trait || "(default user_message)"}" do
        subject(:line) do
          args = [trait].compact
          pm = build(:pending_message, *args, session: session, content: "write me a gh ticket", **overrides)
          pm.decorate.render("melete")
        end

        it "renders as #{expected_line.inspect}" do
          expect(line).to eq(expected_line)
        end
      end
    end

    it "truncates very long content in the middle" do
      long = "x" * 1000
      pm = build(:pending_message, session: session, content: long)
      line = pm.decorate.render("melete")

      expect(line).to start_with("User (pending): ")
      expect(line.length).to be < long.length
      expect(line).to include("[...truncated...]")
    end
  end

  describe "#render('mneme')" do
    {
      nil => "User (pending): please ship it",
      :subagent => "Sub-agent scout (pending): please ship it",
      :tool_response => "tool_response toolu_abc (pending): please ship it"
    }.each do |trait, expected_prefix|
      it "renders #{trait || "user_message"} with the expected attribution" do
        overrides = {content: "please ship it"}
        overrides[:source_name] = "scout" if trait == :subagent
        overrides[:tool_use_id] = "toolu_abc" if trait == :tool_response
        args = [trait].compact
        pm = build(:pending_message, *args, session: session, **overrides)

        expect(pm.decorate.render("mneme")).to eq(expected_prefix)
      end
    end

    it "skips enrichment-side types so they don't pollute associative recall" do
      pm = build(:pending_message, :from_mneme, session: session)
      expect(pm.decorate.render("mneme")).to be_nil
    end
  end

  describe "#render" do
    it "raises on unknown mode" do
      pm = build(:pending_message, session: session)
      expect { pm.decorate.render("basic") }.to raise_error(ArgumentError)
    end
  end
end
