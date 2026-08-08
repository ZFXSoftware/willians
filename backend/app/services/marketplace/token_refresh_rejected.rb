module Marketplace
  # Marcador para "o marketplace recusou a renovação do token".
  #
  # Cada plataforma tem sua própria hierarquia de erro; sem um marcador comum, o
  # TokenProvider precisaria listar as classes de todas elas — e esquecer uma
  # significa não marcar a credencial como expirada, deixando a conta tentando
  # renovar para sempre.
  module TokenRefreshRejected
  end
end
