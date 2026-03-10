# frozen_string_literal: true

module Anima
  # Manages the Anima brain: a Puma web server (Action Cable)
  # and a Solid Queue worker as child processes.
  # Used by `anima start` to run the brain as a persistent service.
  class BrainServer
    PUMA_PORT = 42134

    attr_reader :environment

    def initialize(environment:)
      @environment = environment
      @pids = []
      @shutting_down = false
    end

    # Prepares databases, starts child processes, and blocks until they exit.
    def run
      prepare_databases
      trap_signals
      start_processes
      wait_for_processes
    end

    private

    def prepare_databases
      system(rails_bin, "db:prepare") || abort("db:prepare failed")
    end

    def start_processes
      port = PUMA_PORT.to_s
      env = {"RAILS_ENV" => environment, "PORT" => port}

      @pids << Process.spawn(env, rails_bin, "server", "-p", port)
      @pids << Process.spawn(env, jobs_bin)

      log_startup
    end

    def log_startup
      $stdout.puts "Anima brain started (#{environment}) — PID #{Process.pid}"
      $stdout.puts "  web:    http://localhost:#{PUMA_PORT} (PID #{@pids[0]})"
      $stdout.puts "  worker: Solid Queue (PID #{@pids[1]})"
    end

    def trap_signals
      %w[INT TERM].each do |signal|
        Signal.trap(signal) do
          shutdown_processes unless @shutting_down
        end
      end
    end

    def shutdown_processes
      @shutting_down = true
      @pids.each do |pid|
        Process.kill("TERM", pid)
      rescue Errno::ESRCH
        # Process already gone
      end
    end

    def wait_for_processes
      loop do
        pid, status = Process.waitpid2(-1)
        @pids.delete(pid)
        break if @pids.empty?

        # A child exited unexpectedly — terminate remaining processes
        unless status.success? || @shutting_down
          shutdown_remaining
          break
        end
      end
    rescue Errno::ECHILD
      # All children have exited
    end

    def shutdown_remaining
      shutdown_processes
      @pids.each do |pid|
        Process.waitpid(pid)
      rescue Errno::ECHILD
        # Already reaped
      end
    end

    def rails_bin
      Anima.gem_root.join("bin/rails").to_s
    end

    def jobs_bin
      Anima.gem_root.join("bin/jobs").to_s
    end
  end
end
