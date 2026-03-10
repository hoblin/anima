# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Health check endpoint", type: :request do
  it "responds with 200 at /up" do
    get rails_health_check_path
    expect(response).to have_http_status(:ok)
  end
end
