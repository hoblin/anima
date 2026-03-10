# frozen_string_literal: true

# Rack endpoint for health/liveness checks.
# Mounted at /health — returns 200 with JSON status.
class HealthCheck
  def self.call(_env)
    [200, {"content-type" => "application/json"}, ['{"status":"ok"}']]
  end
end
