# frozen_string_literal: true

Rails.application.routes.draw do
  mount ActionCable.server => "/cable"
  get "up", to: "rails/health#show", as: :rails_health_check
end
