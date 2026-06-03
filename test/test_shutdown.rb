require_relative "helper"

# #188 regression guard for the #186 fix.
#
# A server that does NOT mount the OpenAI events surface (the common case)
# must not SIGSEGV on SIGTERM. The #186 bug: App#initialize never set
# @openai_events, so Tep.on_shutdown's unconditional `openai_events.enabled?`
# was a null-receiver deref -- a hard SIGSEGV under Spinel (exit 139) on a
# clean `kill -TERM`. #186 (0.11.2) initialises @openai_events to a disabled
# default, so on_shutdown is a safe no-op for apps that never call
# Tep::Llm::OpenAI::Server.serve!.
#
# The events-mounted path is already covered by
# test_openai_server#test_sigterm_emits_run_end; this is the no-events path
# that the original bug actually hit. We assert the exit is NOT a SEGV.
# Whether the clean exit is 143 (signal-terminated) or 0 (graceful return)
# is the build/timing-sensitive residual tracked in #188 and is acceptable
# here -- only a SIGSEGV is the regression.
class TestShutdownNoEvents < TepTest
  app_source <<~RB
    require 'sinatra'

    get '/ping' do
      "pong"
    end
  RB

  def test_sigterm_on_no_events_app_does_not_segv
    assert_equal "pong", get("/ping").body, "server should be live before SIGTERM"

    status = TepHarness.terminate_status(@port)
    refute_nil status, "spawned server not found / never reaped"

    segv = Signal.list["SEGV"] # 11 -> exit 139
    crashed = status.signaled? && status.termsig == segv
    refute crashed,
           "no-events app SIGSEGV'd on SIGTERM (the #186 regression) -- " \
           "termsig=#{status.termsig.inspect} exitstatus=#{status.exitstatus.inspect}"
  end
end
