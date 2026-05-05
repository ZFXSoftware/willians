require 'net/http'
require 'json'

class OmieClient
  BASE_URL = "https://app.omie.com.br/api/v1"

  def initialize(app_key:, app_secret:)
    @app_key = app_key
    @app_secret = app_secret
  end

  def request(endpoint, call, params = {})
    uri = URI("#{BASE_URL}#{endpoint}")

    body = {
      call: call,
      app_key: @app_key,
      app_secret: @app_secret,
      param: [params]
    }

    response = Net::HTTP.post(
      uri,
      body.to_json,
      "Content-Type" => "application/json"
    )

    parsed = JSON.parse(response.body)

    if parsed["faultstring"]
      raise "Erro Omie: #{parsed["faultstring"]}"
    end

    parsed
  end
end