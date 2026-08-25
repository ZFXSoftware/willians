module Marketplace
  # Marcador para "a plataforma recusou a credencial nesta chamada".
  #
  # Token vencido, revogado do lado de lá, ou sem o escopo necessário. A
  # providência é sempre a mesma e é do usuário: reconectar a conta.
  #
  # Diferente de [TokenRefreshRejected], que é sobre a RENOVAÇÃO do token ter
  # sido recusada. Um erro pode ser as duas coisas; a maioria é só uma.
  module CredencialRecusada
  end
end
