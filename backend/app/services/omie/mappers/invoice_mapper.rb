module Omie
  module Mappers
    # Monta os payloads para levar uma nota fiscal do Tiny ao OMIE: o cadastro
    # do COMPRADOR e o título a receber dele.
    #
    # Contra o comprador, e não contra o marketplace, porque é assim que o
    # cliente lança hoje — a nota é emitida para o comprador e o título espelha
    # a nota. O código de cliente/fornecedor configurado por conta de
    # marketplace serve para o outro caso: taxas e ajustes que não têm nota, e
    # portanto não têm comprador.
    class InvoiceMapper
      PREFIX = FinancialEntryMapper::INTEGRATION_PREFIX

      class SemComprador < StandardError; end

      def initialize(invoice:, settings:)
        @invoice = invoice

        @settings = settings
      end

      # `codigo_cliente_integracao` é a nossa chave do cadastro: o mesmo
      # documento sempre resolve para o mesmo cliente no OMIE, então reenviar
      # atualiza em vez de duplicar — e 3588 compradores não viram 7176.
      def cliente
        exigir_comprador!

        {
          codigo_cliente_integracao: codigo_cliente,
          razao_social: nome,
          nome_fantasia: nome,
          cnpj_cpf: documento,
          # Pessoa física ou jurídica pelo tamanho do documento: 11 é CPF.
          pessoa_fisica: documento.length <= 11 ? "S" : "N"
        }
      end

      # `codigo_cliente` é o id do cliente NO OMIE, resolvido antes por quem
      # chama — consultando pelo CPF/CNPJ e só criando quando não existe.
      #
      # Antes o título vinha com o nosso `codigo_cliente_integracao`, que só
      # funcionaria se o cadastro tivesse nascido aqui. A base do cliente já
      # tem os compradores, com código de integração vazio: o OMIE recusava a
      # inclusão pelo CPF repetido, e nenhum título era criado.
      def titulo(codigo_cliente:)
        exigir_comprador!

        {
          # Distingue o que é nosso do que o TrackCash criou, e permite
          # reencontrar o título sem depender de valor ou data.
          codigo_lancamento_integracao: "#{PREFIX}-NF-#{invoice.id}",

          codigo_cliente_fornecedor: codigo_cliente,

          # A CHAVE da conciliação. É por ela que o título encontra o repasse
          # do marketplace, e é o único identificador presente em títulos de
          # todas as origens.
          numero_documento: invoice.number,

          data_emissao: data(invoice.issued_at),

          # Decidido com o cliente: vence na data da nota.
          data_vencimento: data(invoice.issued_at),

          data_previsao: data(invoice.issued_at),

          valor_documento: invoice.total_amount.to_f,

          codigo_categoria: settings.categoria_para("sale"),

          id_conta_corrente: settings.conta_corrente_id,

          observacao: "NF #{invoice.number}/#{invoice.series} — pedido #{pedido}"
        }.compact
      end

      def documento = metadata["comprador_documento"].to_s.gsub(/\D/, "")

      # Como veio do Tiny, com pontuação. O OMIE guarda nesse formato — a
      # própria mensagem de erro dele devolve "557.886.962-91" —, e o filtro de
      # busca pode não normalizar.
      def documento_original = metadata["comprador_documento"].to_s.strip

      private

      attr_reader :invoice, :settings

      def metadata = invoice.metadata || {}

      def nome = metadata["comprador_nome"].to_s.strip

      def pedido = invoice.order&.external_id || metadata["numero_ecommerce"]

      def codigo_cliente = "#{PREFIX}-#{documento}"

      # Sem documento não dá para cadastrar o comprador nem garantir que o
      # mesmo cliente não vire dois cadastros. Melhor recusar a nota do que
      # criar cadastro sem identificação na contabilidade de alguém.
      def exigir_comprador!
        return if nome.present? && documento.length.in?([ 11, 14 ])

        raise SemComprador,
              "Nota #{invoice.number} sem CPF/CNPJ utilizável do comprador " \
              "(nome: #{nome.presence || 'ausente'}, documento: #{documento.presence || 'ausente'})."
      end

      def data(valor) = valor&.to_date&.strftime("%d/%m/%Y")
    end
  end
end
