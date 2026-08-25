require "csv"

module Marketplace
  module MercadoLivre
    # Converte o relatório de Liberações em lançamentos do nosso razão.
    #
    # Cada linha do relatório é uma movimentação do saldo. As colunas foram
    # conferidas na documentação (agosto/2026):
    #
    #   DATE                data em que a transação afeta o saldo disponível
    #   SOURCE_ID           id da transação no Mercado Pago (ex.: id do pagamento)
    #   ORDER_ID            pedido de compra — o elo com a NF do Tiny
    #   RECORD_TYPE         tipo do registro (release, payout, ...)
    #   GROSS_AMOUNT        bruto que o vendedor recebe
    #   MP_FEE_AMOUNT       tarifa do Mercado Pago / Mercado Livre
    #   SHIPPING_FEE_AMOUNT custo de envio
    #   TAXES_AMOUNT        impostos retidos
    #   NET_CREDIT_AMOUNT   creditado no disponível
    #   NET_DEBIT_AMOUNT    debitado do disponível
    #
    # Uma linha vira VÁRIOS lançamentos: a venda pelo bruto e uma taxa para
    # cada dedução. É assim que a conciliação compara bruto contra bruto, que é
    # como o título existe no OMIE.
    class ReleaseEvents
      PLATFORM = "mercado_livre".freeze

      # Linhas de resumo do relatório: saldo anterior, total, saldo após saque.
      # Não são movimentação, são cabeçalho de conferência.
      RESUMO = %w[initial_available_balance available_balance total].freeze

      # Saque para a conta bancária. Não é receita nem despesa: é o dinheiro
      # saindo da conta virtual para o banco — o repasse propriamente dito.
      SAQUE = %w[payout withdrawal].freeze

      # Contestação e estorno forçado. O razão já tem esses tipos, e é por eles
      # que a devolução vai ser rastreada até a NF de origem (briefing 2.8).
      DISPUTAS = {
        "chargeback" => :chargeback,
        "dispute" => :dispute,
        "reserve_for_dispute" => :dispute,
        "reserve_for_payout" => :dispute
      }.freeze

      # Cada dedução vira um lançamento próprio, para que a taxa apareça
      # discriminada no razão em vez de sumir dentro do líquido.
      DEDUCOES = {
        "MP_FEE_AMOUNT" => { tipo: :fee, sufixo: "FEE" },
        "SHIPPING_FEE_AMOUNT" => { tipo: :fee, sufixo: "SHIP" },
        "FINANCING_FEE_AMOUNT" => { tipo: :fee, sufixo: "FIN" },
        # Imposto retido é dedução como as demais: o razão não tem tipo próprio
        # para ele, e o sufixo do identificador preserva a distinção.
        "TAXES_AMOUNT" => { tipo: :fee, sufixo: "TAX" },
        "COUPON_AMOUNT" => { tipo: :adjustment, sufixo: "COUPON" }
      }.freeze

      attr_reader :ignorados

      def initialize(csv:)
        @csv = csv.to_s

        # Tipos de registro que não sabemos tratar entram na contagem em vez de
        # sumir em silêncio — o mesmo critério usado na Amazon.
        @ignorados = Hash.new(0)

        @saldos = {}

        @lidas = 0

        @colunas = []

        # TODOS os tipos vistos, e não só os desconhecidos. É o que responde
        # "o relatório tem movimentação mas não tem saldo?" sem abrir o CSV.
        @tipos = Hash.new(0)
      end

      def call
        tabela = linhas

        @lidas = tabela.size

        @colunas = tabela.headers.compact if tabela.respond_to?(:headers)

        eventos = tabela.flat_map { |linha| eventos_de(linha) }.compact

        relatar(eventos)

        eventos
      end

      # O que o leitor viu, para quem precisa explicar um resultado vazio.
      def diagnostico
        {
          linhas: @lidas,
          colunas: @colunas,
          tipos: @tipos.dup,
          ignorados: ignorados.dup,
          saldos: @saldos.keys
        }
      end

      # As linhas de resumo do relatório são o saldo que a PLATAFORMA declara.
      # Não são movimentação — por isso ficam fora do razão —, mas são
      # exatamente o espelho que o briefing 2.4 pede.
      #
      # Depende de `call` ter percorrido o arquivo.
      def saldos
        call if @saldos.empty?

        {
          inicial: @saldos["initial_available_balance"],
          disponivel: @saldos["available_balance"],
          total: @saldos["total"]
        }.compact
      end

      private

      attr_reader :csv

      # Toda leitura deixa registrado o que o relatório tinha DENTRO.
      #
      # A contagem por tipo é o que responde "tem movimentação mas não tem
      # saldo?" — a pergunta que aparece quando a conta claramente vendeu e a
      # conferência de saldo diz que não veio nada. Saldo vem das linhas de
      # resumo, que são registros à parte da movimentação; ter uma não implica
      # ter a outra.
      def relatar(eventos)
        return if @lidas.zero?

        Rails.logger.info(
          "[ReleaseEvents] #{@lidas} linha(s): #{eventos.size} lançamento(s), " \
          "saldos #{@saldos.any? ? @saldos.keys.join('/') : 'AUSENTES'}. " \
          "Tipos: #{@tipos.inspect}"
        )

        avisar_se_mudo(eventos)
      end

      # Relatório com linhas e nenhum evento é o pior tipo de zero: parece "não
      # houve venda" e pode ser "as colunas não são as que eu espero". As
      # colunas reais vão no aviso porque são exatamente o que responde isso —
      # e são nomes de cabeçalho, não dado de ninguém.
      def avisar_se_mudo(eventos)
        return if eventos.any?
        return if @saldos.any?

        Rails.logger.warn(
          "[ReleaseEvents] #{@lidas} linha(s) lida(s) e NENHUM lançamento produzido. " \
          "Colunas recebidas: #{@colunas.join(', ')}. " \
          "Tipos ignorados: #{ignorados.any? ? ignorados.inspect : 'nenhum'}."
        )
      end

      def linhas
        return [] if csv.strip.empty?

        CSV.parse(csv, headers: true, header_converters: ->(h) { h.to_s.strip.upcase })
      rescue CSV::MalformedCSVError => e
        raise ArgumentError, "Relatório de liberações ilegível: #{e.message}"
      end

      def eventos_de(linha)
        tipo = linha["RECORD_TYPE"].to_s.strip.downcase

        @tipos[tipo.presence || "(vazio)"] += 1

        if RESUMO.include?(tipo)
          registrar_saldo(tipo, linha)

          return []
        end

        return [saque(linha)] if SAQUE.include?(tipo)

        return disputa(linha, DISPUTAS[tipo]) if DISPUTAS.key?(tipo)

        unless tipo == "release" || tipo.empty?
          @ignorados[tipo] += 1

          return []
        end

        [venda(linha), *taxas(linha)].compact
      end

      # A linha de resumo traz o valor ora no crédito, ora no bruto, conforme o
      # tipo. Vale o primeiro que não for zero.
      def registrar_saldo(tipo, linha)
        valor = [linha["NET_CREDIT_AMOUNT"], linha["GROSS_AMOUNT"], linha["NET_DEBIT_AMOUNT"]]
                .map { |v| decimal(v) }
                .find { |v| !v.zero? }

        @saldos[tipo] = valor || BigDecimal("0")
      end

      def venda(linha)
        bruto = decimal(linha["GROSS_AMOUNT"])

        return if bruto.zero?

        # Bruto negativo é estorno: a venda voltou.
        estorno = bruto.negative?

        base(linha,
             sufixo: estorno ? "REFUND" : "SALE",
             tipo: estorno ? :refund : :sale,
             direcao: estorno ? :debit : :credit,
             valor: bruto.abs)
      end

      def taxas(linha)
        DEDUCOES.filter_map do |coluna, regra|
          valor = decimal(linha[coluna])

          next if valor.zero?

          # No relatório a dedução chega negativa; devolvida, chega positiva.
          base(linha,
               sufixo: regra[:sufixo],
               tipo: regra[:tipo],
               direcao: valor.negative? ? :debit : :credit,
               valor: valor.abs)
        end
      end

      # A contestação entra pelo bruto, amarrada ao pedido: é o que permite
      # chegar da disputa até a nota fiscal da venda.
      def disputa(linha, tipo)
        valor = decimal(linha["GROSS_AMOUNT"])

        valor = decimal(linha["NET_DEBIT_AMOUNT"]) if valor.zero?

        return [] if valor.zero?

        [base(linha,
              sufixo: tipo.to_s.upcase,
              tipo: tipo,
              direcao: valor.negative? ? :debit : :credit,
              valor: valor.abs)]
      end

      def saque(linha)
        valor = decimal(linha["NET_DEBIT_AMOUNT"])

        valor = decimal(linha["GROSS_AMOUNT"]) if valor.zero?

        base(linha,
             sufixo: "PAYOUT",
             tipo: :settlement,
             direcao: :debit,
             valor: valor.abs,
             com_pedido: false)
      end

      def base(linha, sufixo:, tipo:, direcao:, valor:, com_pedido: true)
        pedido = linha["ORDER_ID"].to_s.strip.presence

        ocorrido = data(linha["DATE"])

        {
          external_id: identificador(linha, sufixo),
          platform: PLATFORM,
          entry_type: tipo,
          direction: direcao,
          amount: valor,
          currency: linha["CURRENCY"].to_s.strip.presence || "BRL",
          occurred_at: ocorrido,
          available_on: ocorrido&.to_date,
          external_order_id: com_pedido ? pedido : nil,
          description: linha["DESCRIPTION"].to_s.strip.presence,
          metadata: {
            "source_id" => linha["SOURCE_ID"].to_s.strip.presence,
            "external_reference" => linha["EXTERNAL_REFERENCE"].to_s.strip.presence,
            "record_type" => linha["RECORD_TYPE"].to_s.strip.presence,
            "payment_method" => linha["PAYMENT_METHOD"].to_s.strip.presence
          }.compact
        }
      end

      # Estável entre execuções: o mesmo relatório reprocessado não duplica.
      # SOURCE_ID identifica a transação no Mercado Pago; sem ele, caímos no
      # pedido + data, que ainda é único por tipo de dedução.
      def identificador(linha, sufixo)
        chave = linha["SOURCE_ID"].to_s.strip.presence ||
                [linha["ORDER_ID"], linha["DATE"]].map { |v| v.to_s.strip }.reject(&:empty?).join("-")

        "MLREL-#{chave}-#{sufixo}"
      end

      def decimal(valor)
        texto = valor.to_s.strip

        return BigDecimal("0") if texto.empty?

        BigDecimal(texto)
      rescue ArgumentError
        BigDecimal("0")
      end

      def data(valor)
        Time.zone.parse(valor.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
