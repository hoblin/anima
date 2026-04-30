# frozen_string_literal: true

module Aoide
  # Strips +from_*+ tool_use blocks from a raw Anthropic response before
  # the rest of the main loop sees them.
  #
  # The +from_*+ prefix is reserved for messages delivered *to* the
  # agent — phantom tool_call/tool_response pairs assembled by
  # +PendingMessage#promote!+ to surface sister-muse and sub-agent
  # output as conversation turns. They are never registered as
  # callable tools, so when the model hallucinates a +from_*+ tool_use
  # block (typically while waiting for a sub-agent's push delivery),
  # +Tools::Registry+ raises +UnknownToolError+, the failure is
  # persisted, and tokens are wasted on a round-trip the model
  # already had to be told not to make. This filter drops those
  # blocks at the entry point of the response handler so they never
  # reach dispatch.
  #
  # Pure: takes a hash, returns a hash. No I/O, no AR, no events.
  module PhantomCallFilter
    PHANTOM_PREFIX = "from_"

    # Returns +response+ with every +from_*+ tool_use block removed
    # from its +content+ array. If no such block is present, returns
    # +response+ unchanged (same object, same identity).
    #
    # @param response [Hash] raw Anthropic response payload
    # @return [Hash] sanitized response
    def self.call(response)
      content = response["content"] || response[:content]
      return response unless content.is_a?(Array)

      filtered = content.reject { |block| phantom_tool_use?(block) }
      return response if filtered.size == content.size

      key = response.key?("content") ? "content" : :content
      response.merge(key => filtered)
    end

    def self.phantom_tool_use?(block)
      return false unless block.is_a?(Hash)

      type = block["type"] || block[:type]
      name = block["name"] || block[:name]
      type == "tool_use" && name.is_a?(String) && name.start_with?(PHANTOM_PREFIX)
    end
    private_class_method :phantom_tool_use?
  end
end
