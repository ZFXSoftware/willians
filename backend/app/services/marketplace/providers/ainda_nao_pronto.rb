module Marketplace
  module Providers
    # "Ainda não está pronto" não é falha, e não é exclusividade do Mercado
    # Livre: relatório gerado de forma assíncrona é o padrão da casa (ML,
    # Amazon). Marcar o erro com isto deixa quem chama distinguir "espere um
    # pouco" de "alguma coisa quebrou" sem conhecer a exceção de cada
    # plataforma.
    #
    # Mora em arquivo próprio porque é isso que o Zeitwerk exige: uma
    # constante, um arquivo com o nome dela. Declarada dentro de
    # base_provider.rb, ela carregava por sorte de ordem — em teste funcionava,
    # e o eager load da produção derrubava o backend no boot.
    module AindaNaoPronto; end
  end
end
