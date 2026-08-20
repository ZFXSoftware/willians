# Dublê de servidor OAuth: registra as chamadas e emite tokens numerados, para
# que o teste consiga distinguir "token original" de "token renovado".
class OauthFalso
  attr_reader :refresh_calls,
              :exchange_calls

  def initialize(expires_in: 21_600, user_id: 555_000_111, prefixo: "")
    @refresh_calls = []
    @exchange_calls = []
    @contador = 0
    @expires_in = expires_in
    @user_id = user_id
    @prefixo = prefixo
  end

  def authorization_url(state:, redirect_uri:, code_challenge: nil)
    query = { response_type: "code", client_id: "APP123", redirect_uri: redirect_uri, state: state }
    query[:code_challenge] = code_challenge if code_challenge

    "https://auth.mercadolivre.com.br/authorization?#{URI.encode_www_form(query)}"
  end

  def exchange_code(code:, redirect_uri: nil, code_verifier: nil, shop_id: nil)
    @exchange_calls << (shop_id ? [code, shop_id] : code)

    tokens(user_id: shop_id || @user_id)
  end

  def refresh(refresh_token:)
    @refresh_calls << refresh_token

    tokens
  end

  private

  def tokens(user_id: @user_id)
    @contador += 1

    { access_token: "#{@prefixo}AT-#{@contador}", refresh_token: "#{@prefixo}RT-#{@contador}",
      expires_in: @expires_in, scope: "read write", user_id: user_id, token_type: "bearer" }
  end
end
