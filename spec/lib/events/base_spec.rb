# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Base do
  subject(:event) { described_class.new(content: "test content") }

  it "requires concrete subclasses to implement #type" do
    expect { event.type }.to raise_error(NotImplementedError, /must implement #type/)
  end

  it "requires concrete subclasses to implement #to_h (indirectly via #type)" do
    expect { event.to_h }.to raise_error(NotImplementedError)
  end

  it "namespaces #event_name under Bus::NAMESPACE" do
    concrete = Events::UserMessage.new(content: "test")
    expect(concrete.event_name).to start_with("#{Events::Bus::NAMESPACE}.")
  end
end
