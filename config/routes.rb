# frozen_string_literal: true

Rails.application.routes.draw do
  mount ActionCable.server => "/cable"
  mount HealthCheck, at: "/health"
end
