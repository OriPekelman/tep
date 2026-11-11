# Given arbitrary strings, both comparison helpers must examine every byte.
require_relative "helper"
require_relative "../../tep/session"
require_relative "../../tep/jwt"

module TimingSafeEqCases
  CASES = {
    "empty" => ["", "", true],
    "ascii_equal" => ["eleven", "eleven", true],
    "ascii_tail" => ["eleven", "eleveX", false],
    "ascii_length" => ["eleven", "eleve", false],
    "empty_nonempty" => ["", "x", false],
    "utf8_equal" => ["é", "é", true],
    "utf8_tail" => ["é", "ê", false],
    "utf8_after_prefix" => ["éa", "éb", false],
    "utf8_byte_length" => ["éé", "éa", false],
    "emoji_equal" => ["🎸", "🎸", true],
    "emoji_tail" => ["🎸", "🎹", false],
    "nul_equal" => ["a\0b", "a\0b", true],
    "nul_tail" => ["a\0b", "a\0c", false]
  }.freeze
end

class TestTimingSafeEqRuby < Minitest::Test
  def test_session_comparison_checks_all_bytes
    TimingSafeEqCases::CASES.each do |name, (left, right, expected)|
      assert_equal expected, Tep.timing_safe_eq(left, right), name
    end
  end

  def test_jwt_comparison_checks_all_bytes
    TimingSafeEqCases::CASES.each do |name, (left, right, expected)|
      assert_equal expected, Tep::Jwt.timing_safe_eq(left, right), name
    end
  end
end

class TestTimingSafeEqNative < TepTest
  app_source "require 'sinatra'\n" + TimingSafeEqCases::CASES.map { |name, (left, right, _expected)|
    <<~RB
      get '/compare/#{name}' do
        left = #{left.inspect}
        right = #{right.inspect}
        session_result = Tep.timing_safe_eq(left, right) ? "yes" : "no"
        jwt_result = Tep::Jwt.timing_safe_eq(left, right) ? "yes" : "no"
        session_result + "|" + jwt_result
      end
    RB
  }.join("\n")

  def test_both_comparisons_check_all_bytes
    TimingSafeEqCases::CASES.each do |name, (_left, _right, expected)|
      value = expected ? "yes" : "no"
      assert_equal value + "|" + value, get("/compare/#{name}").body, name
    end
  end
end
