# frozen_string_literal: true

require "spec_helper"
require "anima/cli"

RSpec.describe Anima::CLI do
  describe "version" do
    it "prints the version" do
      expect { described_class.start(["version"]) }.to output(/anima \d+\.\d+\.\d+/).to_stdout
    end
  end
end
