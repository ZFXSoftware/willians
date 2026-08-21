# Trava única contra chamada real a API externa dentro da suíte de testes.
#
# Existe porque já aconteceu duas vezes: o processo de teste herda o .env, que
# tem credenciais de PRODUÇÃO, e basta um serviço montar o cliente real para a
# suíte sair batendo no OMIE do cliente ou na Shopee. Foi só leitura nas duas
# vezes, por sorte.
#
# Cada cliente HTTP chama `RedeExterna.bloquear!` antes de sair. Ou o teste
# injeta um dublê, ou isto estoura com a mensagem dizendo o que fazer.
module RedeExterna
  class Bloqueada < StandardError; end

  PERMISSAO = "PERMITIR_REDE_EM_TESTE".freeze

  def self.permitida?
    %w[true 1].include?(ENV[PERMISSAO].to_s.strip.downcase)
  end

  def self.bloquear!(servico, detalhe = nil)
    return unless Rails.env.test?

    return if permitida?

    raise Bloqueada,
          "Chamada real a #{servico}#{detalhe ? " (#{detalhe})" : ''} a partir de um teste. " \
          "Injete um dublê no serviço, ou defina #{PERMISSAO}=true para um teste de " \
          "integração deliberado."
  end
end
