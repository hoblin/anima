# frozen_string_literal: true

# Anima brain server — serves Action Cable WebSocket connections
# and health check endpoint. Port 42134 by default.

threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

port ENV.fetch("PORT", 42134)

pidfile ENV.fetch("PIDFILE", File.expand_path("~/.anima/tmp/pids/puma.pid"))

plugin :tmp_restart
