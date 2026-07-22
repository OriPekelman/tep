# boilerplate includes
require 'rubygems'
require 'bundler'

# remainder of includes handled by bundler and the Gemfile
Bundler.require


# define settings
configure do
    set :version, "0.0.1"
end

# define helpers
helpers do
  def h(text)
    # used to safely escape html
    Rack::Utils.escape_html(text)
  end
end

# create routes
get '/' do
    erb :index
end

get '/welcome/:name' do
    @name = params[:name]
    erb :welcomer
end

get '/goodbye/:name' do
    @name = params[:name]
    erb :leaver
end

# below here we have templates
__END__
@@welcomer
<h3>Using the "welcomer" inline template</h3>
<h1>

    Greetings <%=h @name %>
</h1>
<h5>
    Version <%= settings.version %>
</h5>

@@leaver
<h3>Using the "leaver" inline template</h3>
<h1>
    Seeya later <%=h @name %>
</h1>
<h5>
    Version <%= settings.version %>
</h5>
