# frozen_string_literal: true

module Api
  # REST endpoint for session management. The TUI client uses this to
  # obtain a session ID before subscribing to the WebSocket channel.
  class SessionsController < ApplicationController
    # Returns the most recent session or creates one if none exist.
    #
    # GET /api/sessions/current
    # @return [JSON] { id: Integer }
    def current
      session = Session.order(id: :desc).first || Session.create!
      render json: {id: session.id}
    end

    # Creates a new conversation session.
    #
    # POST /api/sessions
    # @return [JSON] { id: Integer }
    def create
      session = Session.create!
      render json: {id: session.id}, status: :created
    end
  end
end
