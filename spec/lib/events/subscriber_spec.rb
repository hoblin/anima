# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscriber do
  it "requires concrete subscribers to implement #emit" do
    bare_subscriber = Class.new { include Events::Subscriber }.new
    expect { bare_subscriber.emit({}) }.to raise_error(NotImplementedError, /must implement #emit/)
  end
end
