# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::Sessions", type: :request do
  describe "GET /api/sessions/current" do
    it "returns the most recent session" do
      Session.create!
      newer = Session.create!

      get "/api/sessions/current"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["id"]).to eq(newer.id)
    end

    it "creates a session if none exist" do
      expect { get "/api/sessions/current" }.to change(Session, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["id"]).to be_a(Integer)
    end
  end

  describe "POST /api/sessions" do
    it "creates a new session" do
      expect { post "/api/sessions" }.to change(Session, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["id"]).to be_a(Integer)
    end

    it "creates a distinct session each time" do
      post "/api/sessions"
      first_id = JSON.parse(response.body)["id"]

      post "/api/sessions"
      second_id = JSON.parse(response.body)["id"]

      expect(second_id).not_to eq(first_id)
    end
  end
end
