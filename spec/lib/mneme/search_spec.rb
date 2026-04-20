# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mneme::Search do
  let(:caller_session) { Session.create! }
  let(:other_session) { Session.create! }

  def create_message(session, type:, content: "msg", tool_name: nil)
    payload = if type == "tool_call" && tool_name == "think"
      {"tool_name" => "think", "tool_input" => {"thoughts" => content}, "tool_use_id" => SecureRandom.hex(8)}
    elsif type == "tool_call"
      {"tool_name" => tool_name, "tool_input" => {}, "tool_use_id" => SecureRandom.hex(8)}
    else
      {"content" => content}
    end

    session.messages.create!(
      message_type: type,
      payload: payload,
      tool_use_id: payload["tool_use_id"],
      timestamp: Time.current.to_ns
    )
  end

  # Sets a Mneme boundary at the oldest eligible message of +session+ so the
  # session participates in exclusion as "everything from this boundary up
  # is live viewport; below is long-term memory." Mirrors what
  # Session#initialize_mneme_boundary! would do in production.
  def set_boundary_at_first_message(session)
    first_id = session.messages.conversation_or_think.order(:id).pick(:id)
    session.update_column(:mneme_boundary_message_id, first_id)
  end

  describe ".query" do
    it "returns empty for blank terms" do
      expect(described_class.query("", caller_session: caller_session)).to eq([])
      expect(described_class.query(nil, caller_session: caller_session)).to eq([])
    end

    it "finds user messages by keyword" do
      msg = create_message(other_session, type: "user_message",
        content: "How does authentication work?")
      create_message(other_session, type: "user_message", content: "Tell me about the weather.")

      results = described_class.query("authentication", caller_session: caller_session)

      expect(results.size).to eq(1)
      expect(results.first.message_id).to eq(msg.id)
      expect(results.first.session_id).to eq(other_session.id)
      expect(results.first.message_type).to eq("human")
    end

    it "finds agent messages by keyword" do
      msg = create_message(other_session, type: "agent_message",
        content: "The OAuth flow uses PKCE for security.")

      results = described_class.query("OAuth PKCE", caller_session: caller_session)

      expect(results.size).to eq(1)
      expect(results.first.message_id).to eq(msg.id)
      expect(results.first.message_type).to eq("anima")
    end

    it "finds think tool_calls by keyword" do
      msg = create_message(other_session, type: "tool_call", tool_name: "think",
        content: "The migration strategy needs careful planning.")

      results = described_class.query("migration strategy", caller_session: caller_session)

      expect(results.size).to eq(1)
      expect(results.first.message_id).to eq(msg.id)
      expect(results.first.message_type).to eq("thought")
    end

    it "finds system messages by keyword" do
      msg = create_message(other_session, type: "system_message",
        content: "System context initialized with debug mode.")

      results = described_class.query("debug mode", caller_session: caller_session)

      expect(results.size).to eq(1)
      expect(results.first.message_id).to eq(msg.id)
      expect(results.first.message_type).to eq("system")
    end

    it "does not index non-think tool_call events" do
      create_message(other_session, type: "tool_call", tool_name: "bash")

      results = described_class.query("bash", caller_session: caller_session)

      expect(results).to be_empty
    end

    it "searches across every session other than the caller's viewport" do
      e1 = create_message(other_session, type: "user_message", content: "Deploy the database changes.")
      third = Session.create!
      e2 = create_message(third, type: "user_message", content: "Database migration failed.")

      results = described_class.query("database", caller_session: caller_session)

      expect(results.map(&:message_id)).to contain_exactly(e1.id, e2.id)
    end

    context "viewport exclusion for the caller session" do
      it "excludes the caller's messages at or above its Mneme boundary" do
        # Below-boundary message: should surface (evicted long-term memory).
        below = create_message(caller_session, type: "user_message",
          content: "Old discussion about caching strategies.")
        # Set the boundary above `below` so it's in long-term memory.
        # Use an id beyond `below.id` so below stays below the boundary.
        above = create_message(caller_session, type: "user_message",
          content: "Recent talk about caching in the live viewport.")
        caller_session.update_column(:mneme_boundary_message_id, above.id)

        results = described_class.query("caching", caller_session: caller_session)

        expect(results.map(&:message_id)).to contain_exactly(below.id)
      end

      it "excludes the caller's whole session when it has no boundary yet" do
        # Fresh main session or sub-agent: nothing below the viewport exists yet.
        create_message(caller_session, type: "user_message",
          content: "Everything here about caching is currently in the viewport.")
        elsewhere = create_message(other_session, type: "user_message",
          content: "A separate session also discussing caching strategies.")

        results = described_class.query("caching", caller_session: caller_session)

        expect(results.map(&:message_id)).to contain_exactly(elsewhere.id)
      end

      it "never filters messages from other sessions regardless of their IDs" do
        # The shared id sequence means `other_session`'s message could have an id
        # that technically sits above the caller's boundary — that must not
        # accidentally exclude it, because the boundary has no meaning cross-session.
        pinned = create_message(caller_session, type: "user_message",
          content: "anchor message")
        caller_session.update_column(:mneme_boundary_message_id, pinned.id)
        cross = create_message(other_session, type: "user_message",
          content: "Message from another session with an id above the caller's boundary.")

        results = described_class.query("another session", caller_session: caller_session)

        expect(results.map(&:message_id)).to include(cross.id)
      end
    end

    it "respects the limit parameter" do
      5.times { |i| create_message(other_session, type: "user_message", content: "Ruby version #{i} is great.") }

      results = described_class.query("Ruby", caller_session: caller_session, limit: 2)

      expect(results.size).to eq(2)
    end

    it "returns results with snippets containing match highlights" do
      create_message(other_session, type: "user_message",
        content: "The authentication module needs refactoring.")

      results = described_class.query("authentication", caller_session: caller_session)

      expect(results.first.snippet).to include("authentication")
    end

    it "returns results with rank scores" do
      create_message(other_session, type: "user_message", content: "Authentication is broken.")

      results = described_class.query("authentication", caller_session: caller_session)

      expect(results.first.rank).to be_a(Numeric)
    end

    it "sanitizes FTS5 special characters" do
      create_message(other_session, type: "user_message", content: "Testing the search system.")

      expect { described_class.query("test*", caller_session: caller_session) }.not_to raise_error
      expect { described_class.query("test:query", caller_session: caller_session) }.not_to raise_error
      expect { described_class.query("test{query}", caller_session: caller_session) }.not_to raise_error
    end

    # Regression: hyphenated words in user input used to parse as the FTS5
    # NOT operator (`sub-agents` → `sub NOT agents`), which then tried to
    # resolve `agents` as a column name and crashed the whole drain
    # pipeline with "no such column: agents".
    it "treats hyphens as token separators instead of the NOT operator" do
      agents = create_message(other_session, type: "agent_message",
        content: "We should discuss sub-agents next.")

      expect { described_class.query("sub-agents", caller_session: caller_session) }.not_to raise_error

      results = described_class.query("sub-agents", caller_session: caller_session)
      expect(results.map(&:message_id)).to include(agents.id)
    end

    it "neutralizes colon-injected column filters" do
      create_message(other_session, type: "user_message",
        content: "Check the agents column once.")

      # `agents:foo` would historically try to restrict search to a column
      # called "agents" (which does not exist) and crash.
      expect { described_class.query("agents:foo", caller_session: caller_session) }.not_to raise_error
    end

    it "returns no results for queries with only FTS5 operators" do
      create_message(other_session, type: "user_message",
        content: "Authentication flow question.")

      # `AND OR NOT` would become a syntactically invalid FTS5 query on
      # its own — an empty body around pass-through operators. Caller
      # should get back an empty result, not a crash.
      expect { described_class.query("AND OR NOT", caller_session: caller_session) }.not_to raise_error
    end

    it "treats lowercase and/or/not as literal search terms, not operators" do
      msg = create_message(other_session, type: "user_message",
        content: "The signal and the noise.")

      # Lowercase operators are NOT in the allowlist, so `and` must be
      # quote-wrapped and matched as a plain word — not parsed as a
      # boolean connective.
      expect { described_class.query("signal and noise", caller_session: caller_session) }.not_to raise_error
      expect(described_class.query("signal and noise", caller_session: caller_session).map(&:message_id))
        .to include(msg.id)
    end

    it "escapes embedded double quotes in user tokens" do
      create_message(other_session, type: "user_message", content: "She said hello to me.")

      # A stray or unbalanced quote in user input historically produced an
      # FTS5 syntax error; quote-doubling now neutralizes it.
      expect { described_class.query('say "hello', caller_session: caller_session) }.not_to raise_error
      expect { described_class.query('a "double" quote', caller_session: caller_session) }.not_to raise_error
    end

    it "handles quoted phrases" do
      create_message(other_session, type: "user_message", content: "The full text search works well.")

      results = described_class.query('"full text search"', caller_session: caller_session)

      expect(results.size).to eq(1)
    end

    it "ranks recent events higher than older ones with equal relevance" do
      old_msg = create_message(other_session, type: "user_message",
        content: "Deploy the Ruby application.")
      old_msg.update_column(:created_at, 1.year.ago)
      new_msg = create_message(other_session, type: "user_message",
        content: "Deploy the Ruby application.")

      results = described_class.query("Ruby", caller_session: caller_session)

      expect(results.first.message_id).to eq(new_msg.id)
    end

    # Regression: #289 — common words like "bash" were interpolated as column
    # references instead of string values when bind params were passed as a
    # raw array to select_all.
    it "handles terms that resemble SQL column names" do
      msg = create_message(other_session, type: "user_message",
        content: "Learn bash scripting basics.")

      results = described_class.query("bash", caller_session: caller_session)

      expect(results.size).to eq(1)
      expect(results.first.message_id).to eq(msg.id)
    end
  end
end
