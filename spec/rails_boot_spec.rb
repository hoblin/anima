# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Rails application" do
  it "boots successfully" do
    expect(Rails.application).to be_a(Anima::Application)
  end

  it "is API-only" do
    expect(Rails.application.config.api_only).to be true
  end

  it "uses SQLite3" do
    config = ActiveRecord::Base.connection_db_config
    expect(config.adapter).to eq("sqlite3")
  end

  it "stores databases in ~/.anima/db/" do
    db_path = ActiveRecord::Base.connection_db_config.database
    expect(db_path).to include(".anima/db/")
  end

  it "runs in test environment" do
    expect(Rails.env).to eq("test")
  end
end
