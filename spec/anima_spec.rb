# frozen_string_literal: true

RSpec.describe Anima do
  it "has a version number" do
    expect(Anima::VERSION).not_to be_nil
  end

  it "has a semantic version format" do
    expect(Anima::VERSION).to match(/\A\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?\z/)
  end

  describe Anima::Error do
    it "is a StandardError subclass" do
      expect(Anima::Error).to be < StandardError
    end
  end
end
