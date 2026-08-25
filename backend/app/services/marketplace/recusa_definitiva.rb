module Marketplace
  # Quais respostas de OAuth significam "não adianta tentar de novo".
  #
  # Existe porque a distinção estava faltando e o preço era alto: qualquer erro
  # do endpoint de token — um 500 do Mercado Livre, um 429, uma instabilidade
  # de dez segundos — marcava a credencial como expirada, e o lojista era
  # desconectado e tinha que refazer o OAuth. Um soluço da plataforma virava
  # trabalho manual.
  #
  # Recusa definitiva é o refresh_token não valer mais: revogado pelo lojista,
  # vencido, ou já usado (eles são de uso único). O OAuth2 chama isso de
  # `invalid_grant`, e é o único caso em que reconectar é a providência.
  #
  # Todo o resto é transitório: registra o erro para aparecer na tela, mantém a
  # credencial conectada, e a próxima renovação tenta de novo.
  module RecusaDefinitiva
    CODIGOS = %w[invalid_grant unauthorized_grant].freeze

    def self.definitiva?(codigo)
      CODIGOS.include?(codigo.to_s.strip.downcase)
    end
  end
end
