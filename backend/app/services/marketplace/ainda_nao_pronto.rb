module Marketplace
  # Marcador para "o dado ainda não está pronto — espere".
  #
  # Relatório gerado de forma assíncrona é o padrão da casa (Mercado Livre,
  # Amazon), e "ainda não" é uma resposta diferente de "não deu para ler": a
  # primeira passa sozinha, a segunda pede alguém. Sem um marcador comum, quem
  # chama precisaria conhecer a exceção de cada plataforma — e esquecer uma
  # significa reportar espera normal como falha.
  #
  # Mesma ideia de [TokenRefreshRejected].
  module AindaNaoPronto
  end
end
