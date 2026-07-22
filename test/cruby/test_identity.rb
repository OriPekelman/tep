require_relative "helper"

# Tep::Identity + Tep::AgentDelegation: the principal+delegate
# identity types Auth issues and Broadcast/Presence/LiveView consume.
# See docs/BATTERIES-DESIGN.md for the broader Auth design.
class TestIdentity < TepTest
  app_source <<~RB
    require 'sinatra'

    HUMAN_CAPS = [:read, :write]
    AGENT_CAPS = [:read]

    HUMAN = Tep::Identity.new("user:42", nil, HUMAN_CAPS)

    BOT_DELEGATION = Tep::AgentDelegation.new(
      "summarizer-bot", 1000, 2000, :token)
    AGENT = Tep::Identity.new("user:42", BOT_DELEGATION, AGENT_CAPS)

    # Plain-text helper so every route returns the answer directly.
    before do
      res.headers["Content-Type"] = "text/plain"
    end

    get '/human/subject' do
      HUMAN.subject
    end

    get '/human/is_human' do
      HUMAN.human? ? "yes" : "no"
    end

    get '/human/is_agent' do
      HUMAN.agent? ? "yes" : "no"
    end

    get '/human/may_read' do
      HUMAN.may?(:read) ? "yes" : "no"
    end

    get '/human/may_post_summary' do
      HUMAN.may?(:post_summary) ? "yes" : "no"
    end

    get '/agent/subject' do
      AGENT.subject
    end

    get '/agent/is_human' do
      AGENT.human? ? "yes" : "no"
    end

    get '/agent/is_agent' do
      AGENT.agent? ? "yes" : "no"
    end

    get '/agent/may_read' do
      AGENT.may?(:read) ? "yes" : "no"
    end

    get '/agent/may_write' do
      AGENT.may?(:write) ? "yes" : "no"
    end

    get '/agent/agent_id' do
      AGENT.acting_via.agent_id
    end

    get '/agent/origin' do
      AGENT.acting_via.origin.to_s
    end

    get '/agent/expired_before' do
      AGENT.acting_via.expired?(1500) ? "yes" : "no"
    end

    get '/agent/expired_after' do
      AGENT.acting_via.expired?(2500) ? "yes" : "no"
    end

    get '/anonymous/subject' do
      Tep::Identity.anonymous.subject
    end

    get '/anonymous/may_read' do
      Tep::Identity.anonymous.may?(:read) ? "yes" : "no"
    end

    get '/anonymous/is_human' do
      Tep::Identity.anonymous.human? ? "yes" : "no"
    end
  RB

  def test_human_subject_format
    assert_equal "user:user:42", get("/human/subject").body
  end

  def test_human_is_human
    assert_equal "yes", get("/human/is_human").body
  end

  def test_human_is_not_agent
    assert_equal "no", get("/human/is_agent").body
  end

  def test_human_has_granted_cap
    assert_equal "yes", get("/human/may_read").body
  end

  def test_human_lacks_ungranted_cap
    assert_equal "no", get("/human/may_post_summary").body
  end

  def test_agent_subject_format
    assert_equal "agent:summarizer-bot/user:42", get("/agent/subject").body
  end

  def test_agent_is_not_human
    assert_equal "no", get("/agent/is_human").body
  end

  def test_agent_is_agent
    assert_equal "yes", get("/agent/is_agent").body
  end

  def test_agent_has_granted_cap
    assert_equal "yes", get("/agent/may_read").body
  end

  def test_agent_lacks_principal_cap
    # Principal HUMAN has :write; AGENT was granted only :read.
    # Cap subset not superset.
    assert_equal "no", get("/agent/may_write").body
  end

  def test_agent_delegation_exposes_agent_id
    assert_equal "summarizer-bot", get("/agent/agent_id").body
  end

  def test_agent_delegation_exposes_origin
    assert_equal "token", get("/agent/origin").body
  end

  def test_delegation_not_expired_before_window
    assert_equal "no", get("/agent/expired_before").body
  end

  def test_delegation_expired_after_window
    assert_equal "yes", get("/agent/expired_after").body
  end

  def test_anonymous_subject_is_empty_principal
    assert_equal "user:", get("/anonymous/subject").body
  end

  def test_anonymous_has_no_capabilities
    assert_equal "no", get("/anonymous/may_read").body
  end

  def test_anonymous_is_human
    # Without a delegation, anonymous is technically "human" per the
    # acting_via shape. Apps gating routes by anonymous-vs-not check
    # principal_id == "" or use a wrapping helper.
    assert_equal "yes", get("/anonymous/is_human").body
  end
end
