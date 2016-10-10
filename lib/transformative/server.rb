module Transformative
  class Server < Sinatra::Application

    configure do
      root_path = "#{File.dirname(__FILE__)}/../../"
      set :config_path, "#{root_path}config/"
      set :server, :puma
    end

    get '/' do
      'Transformative'
    end

    post '/micropub' do
      require_auth
      puts "MICROPUB PARAMS #{params}"
      begin
        # start by assuming this is a non-create action
        if params.key?('action')
          verify_action
          verify_url
          post = Micropub.action(params)
          syndicate(post)
          status 204
        else
          # if it's not an update/delete/undelete then hopefully it's a create
          post = Micropub.create(params)
          syndicate(post)
          headers 'Location' => post.url
          status 201
        end
      rescue Request§Error => e
        halt_error(e)
      end
    end

    get '/micropub' do
      require_auth
      if params.key?('q')
        headers 'Content-Type' => 'application/json'
        case params[:q]
        when 'source'
          render_source
        when 'config'
          render_config
        when 'syndicate-to'
          render_syndication_targets
        else
          # Silently fail if query method is not supported
        end
      else
        'Micropub endpoint'
      end
    end

    get '/webmention' do
      "Webmention endpoint"
    end

    post '/webmention' do
      require_auth
      require_source
      require_target
      halt if params[:source] == params[:target]
      halt if params[:target] == ENV['ROOT_URL']
      begin
        Webmention.receive(params[:source], params[:target])
        headers 'Location' => params[:target]
        status 202
      rescue WebmentionError => e
        Notify.send("Webmention failed: #{e.type}", e.message, params[:source])
        halt_error(e)
      end
    end

    post '/built' do
      begin
        posts = Store.process_build(params)
        puts "built posts=#{posts}"
      rescue StoreError => e
        halt_error(e)
      end
      status 200
    end

    private

    def require_auth
      return unless settings.production?
      token = request.env['HTTP_AUTHORIZATION'] || params['access_token'] || ""
      token.gsub!('Bearer ','')
      if token.empty?
        raise Auth::NoTokenError.new
      end
      unless Auth.valid_token?(token)
        raise Auth::ForbiddenError.new
      end
    end

    def verify_action
      valid_actions = %w( update delete undelete )
      unless valid_actions.include?(params[:action])
        raise Micropub::InvalidRequestError.new(
          "The specified action ('#{params[:action]}) is not supported. " +
          "Valid actions are: #{valid_actions.join(', ')}."
        )
      end
    end

    def verify_url
      unless params.key?('url') && !params[:url].empty? &&
          Post.exists_by_url?(params[:url])
        raise Micropub::InvalidRequestError.new(
          "The specified URL ('#{params[:url]}') could not be found."
        )
      end
    end

    def halt_error(error)
      json = {
        error: error.type,
        error_description: error.message
      }.to_json
      halt(error.status_code, {'Content-Type' => 'application/json'}, json)
    end

    def syndication_targets
      @syndication_targets ||=
        JSON.parse(File.read("#{settings.config_path}syndication_targets.json"))
    end

    def render_syndication_targets
      content_type :json
      { "syndicate-to" => syndication_targets }.to_json
    end

    def render_config
      content_type :json
      {
        # "media-endpoint" => media_endpoint, # TODO media endpoint
        "syndicate-to" => syndication_targets
      }.to_json
    end

    def render_source
      source = Micropub.source(params)
      puts "source=#{source}"
      body = { properties: source[:properties] }
      body[:type] = source[:type] unless params.key?('properties')
      content_type :json
      body.to_json
    end

    def syndicate(post)
      if params.key?('mp-syndicate-to') && !params['mp-syndicate-to'].empty?
        # list of services may or may not be an array
        services = Array(params['mp-syndicate-to'])
        post.syndicate(services)
      end
    end

  end
end
