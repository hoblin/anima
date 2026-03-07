# frozen_string_literal: true

require "spec_helper"
require "anima/installer"

RSpec.describe Anima::Installer do
  describe "DIRECTORIES" do
    it "includes expected directories" do
      expect(described_class::DIRECTORIES).to include("db", "config/credentials", "log", "tmp")
    end
  end

  describe "ANIMA_HOME" do
    it "points to ~/.anima" do
      expect(described_class::ANIMA_HOME.to_s).to eq(File.expand_path("~/.anima"))
    end
  end
end
