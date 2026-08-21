module Divergencias
  # Briefing 2.5 — leva o usuário à central da plataforma com a contestação
  # pronta para colar.
  #
  # As plataformas não aceitam contestação por link parametrizado: não existe
  # URL pública que abra um formulário já preenchido. O que dá para fazer com
  # honestidade é levar ao lugar certo (a venda, no painel do vendedor) e
  # entregar os dados formatados para colar — que é o trabalho manual que o
  # cliente faz hoje garimpando planilha.
  #
  # O modelo da URL é configurável por plataforma justamente porque o caminho
  # da central muda e não é documentado.
  class Contestacao
    # Usada quando não há pedido para montar o link específico.
    FALLBACK = {
      "mercado_livre" => "https://www.mercadolivre.com.br/ajuda",
      "shopee" => "https://seller.shopee.com.br",
      "amazon" => "https://sellercentral.amazon.com.br/help/hub/support"
    }.freeze

    def initialize(divergencia)
      @divergencia = divergencia
    end

    def call
      {
        url: url,
        url_confirmada: false,
        plataforma: plataforma,
        assunto: assunto,
        texto: texto,
        campos: campos
      }
    end

    private

    attr_reader :divergencia

    def lancamento = divergencia.financial_entry

    def pedido = lancamento&.order

    def nota = lancamento&.invoice

    def plataforma
      lancamento&.platform_account&.platform ||
        divergencia.metadata["platform"]
    end

    def url
      modelo = modelo_configurado

      return fallback if modelo.blank?

      # Sem pedido, um link com o marcador vazio levaria a uma página inexistente.
      return fallback if modelo.include?("{pedido}") && referencia_do_pedido.blank?

      modelo
        .gsub("{pedido}", referencia_do_pedido.to_s)
        .gsub("{nf}", nota&.number.to_s)
    end

    def modelo_configurado
      return if plataforma.blank?

      Integracoes::Config.get(plataforma, :url_contestacao, tenant: divergencia.tenant)
    rescue ArgumentError
      # Plataforma sem entrada no catálogo.
      nil
    end

    def fallback = FALLBACK[plataforma.to_s] || FALLBACK["mercado_livre"]

    def referencia_do_pedido
      pedido&.external_id.presence || divergencia.metadata["order_external_id"].presence
    end

    def assunto
      "Divergência de repasse#{referencia_do_pedido.present? ? " — pedido #{referencia_do_pedido}" : ''}"
    end

    # Texto pronto para colar na central. Escrito em primeira pessoa do
    # vendedor, porque é ele quem envia.
    def texto
      linhas = [
        "Identifiquei uma divergência no repasse desta venda.",
        "",
        *campos.map { |campo| "#{campo[:rotulo]}: #{campo[:valor]}" },
        "",
        "Solicito a revisão do valor repassado e o ajuste da diferença."
      ]

      linhas.join("\n")
    end

    def campos
      [
        campo("Pedido", referencia_do_pedido),
        campo("Nota fiscal", nota&.number),
        campo("Data da ocorrência", data(lancamento&.occurred_at || divergencia.created_at)),
        campo("Valor esperado", dinheiro(divergencia.expected_amount)),
        campo("Valor recebido", dinheiro(divergencia.received_amount)),
        campo("Diferença", dinheiro(divergencia.difference_amount)),
        campo("Referência interna", lancamento&.external_id)
      ].compact
    end

    def campo(rotulo, valor)
      return if valor.blank?

      { rotulo: rotulo, valor: valor.to_s }
    end

    def dinheiro(valor)
      return if valor.blank?

      format("R$ %.2f", valor.to_d).tr(".", ",")
    end

    def data(valor)
      valor&.to_date&.strftime("%d/%m/%Y")
    end
  end
end
