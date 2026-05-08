require_relative "helper"

class TestModular < TepTest
  app_source <<~RB
    require 'sinatra/base'

    class Api < Sinatra::Base
      before do
        response.headers["X-App"] = "Api"
      end

      get '/api/health' do
        "ok"
      end
    end

    class Admin < Sinatra::Base
      get '/admin/dashboard' do
        "admin"
      end
    end

    Api.run!
    Admin.run!
  RB

  def test_first_app_route
    res = get("/api/health")
    assert_equal "200", res.code
    assert_equal "ok", res.body
  end

  def test_second_app_route
    res = get("/admin/dashboard")
    assert_equal "200", res.code
    assert_equal "admin", res.body
  end

  def test_modular_before_filter_ran
    res = get("/api/health")
    assert_equal "Api", res["x-app"]
  end
end
