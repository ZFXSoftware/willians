module Marketplace
  # A conta foi conectada sem acesso offline, então não há token de renovação.
  #
  # É recusa DEFINITIVA — daí o marcador: nenhuma tentativa futura vai
  # funcionar, e retentar de hora em hora só adiaria a única providência que
  # resolve, que é reconectar com o acesso offline ligado no painel da
  # plataforma.
  #
  # Vale pelo que EVITA: sem esta checagem, o pedido de renovação ia sem o
  # parâmetro e a plataforma devolvia a reclamação dela na cara do usuário —
  # "Missing parameters: refresh_token" —, que não diz o que fazer e parece
  # defeito de código.
  class SemRefreshToken < StandardError
    include TokenRefreshRejected
  end
end
