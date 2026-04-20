# frozen_string_literal: true

module Mneme
  module Tools
    # Finish-line tool for {Mneme::RecallRunner}. The muse calls this when
    # she's done her work — whether she surfaced memories or decided
    # nothing was worth carrying forward. Having a single finish line makes
    # every recall run explicit: silence is intentional, not a timeout.
    #
    # Mirror of {EverythingOk} for the eviction runner.
    class NothingToSurface < ::Tools::Base
      def self.tool_name = "nothing_to_surface"

      def self.description = "Finish the recall run. Call this when you're done — whether you surfaced memories or decided nothing was worth surfacing right now. Silence is a valid answer when older memory wouldn't help."

      def self.input_schema
        {type: "object", properties: {}, required: []}
      end

      def execute(_input)
        "Acknowledged."
      end
    end
  end
end
