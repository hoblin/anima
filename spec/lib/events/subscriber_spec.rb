# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscriber do
  let(:bare_subscriber) do
    Class.new { include Events::Subscriber }.new
  end

  describe "#emit" do
    it "raises NotImplementedError when not overridden" do
      expect { bare_subscriber.emit({}) }.to raise_error(NotImplementedError, /must implement #emit/)
    end
  end

  it "is included by SubagentMessageRouter" do
    expect(Events::Subscribers::SubagentMessageRouter.ancestors).to include(described_class)
  end
end
