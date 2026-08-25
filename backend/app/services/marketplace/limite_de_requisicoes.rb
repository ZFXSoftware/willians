module Marketplace
  # Marcador para "a plataforma cortou por excesso de requisições".
  #
  # Não é defeito nosso nem do usuário: passa esperando. Vale separar de
  # [CredencialRecusada] justamente porque a providência é o oposto — ali é
  # reconectar, aqui é não fazer nada.
  module LimiteDeRequisicoes
  end
end
