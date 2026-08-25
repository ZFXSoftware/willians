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

      # Vírgula primeiro só para desempate: o real usa ponto e vírgula.
      SEPARADORES = [ ",", ";" ].freeze

      # Colunas que poderiam trazer o número do pedido — o elo com a NF do
      # Tiny. Contadas a cada leitura para que "o lançamento não tem pedido"
      # tenha resposta sem ninguém abrir o CSV.
      IDENTIFICADORES = %w[ORDER_ID PURCHASE_ID EXTERNAL_REFERENCE SOURCE_ID].freeze

      # O arquivo não traz a coluna que diz o que cada linha É.
      class LayoutDesconhecido < StandardError; end

      class ValorIlegivel < StandardError; end

      # Linhas de resumo do relatório: saldo anterior, total, saldo após saque.
      # Não são movimentação, são cabeçalho de conferência.
      RESUMO = %w[initial_available_balance available_balance total].freeze

      # Dinheiro entrando por uma venda. No arquivo real do cliente o código é
      # `payment`; `release` é o nome da documentação, mantido porque não custa
      # e o formato varia entre contas.
      VENDA = %w[payment release].freeze

      # Saque para a conta bancária. Não é receita nem despesa: é o dinheiro
      # saindo da conta virtual para o banco — o repasse propriamente dito.
      SAQUE = %w[payout withdrawal].freeze

      # Dinheiro trocando de bolso DENTRO da conta do Mercado Pago: sai do
      # disponível e fica reservado até a transferência sair. Não é receita,
      # não é despesa, e o par de lançamentos se anula.
      #
      # Ficam FORA do razão porque a saída de dinheiro já é registrada pelo
      # `payout`. Importar a reserva também contaria a mesma saída duas vezes,
      # e o saldo passaria a acusar uma diferença que não existe.
      #
      # O relatório do cliente confirma o pareamento: 18 `reserve_for_payout`
      # para 9 `payout` — dois por transferência, um reservando e outro
      # liberando.
      MOVIMENTO_INTERNO = %w[reserve_for_payout reserve_for_payment].freeze

      # Contestação e estorno forçado. O razão já tem esses tipos, e é por eles
      # que a devolução vai ser rastreada até a NF de origem (briefing 2.8).
      #
      # `reserve_for_payout` ESTAVA aqui, e não é disputa nenhuma: é a reserva
      # que antecede a transferência para o banco. Classificado como disputa,
      # ele abriria uma contestação inventada a cada saque.
      DISPUTAS = {
        "chargeback" => :chargeback,
        "dispute" => :dispute,
        "reserve_for_dispute" => :dispute
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

        @internos = Hash.new(0)
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
          internos: @internos.dup,
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

      # O arquivo real não tem RECORD_TYPE: quem carrega o tipo é DESCRIPTION,
      # e com os mesmos códigos (payment, payout, reserve_for_payout). Não é
      # descrição em prosa, é o campo do tipo com outro nome.
      def tipo_da(linha)
        valor = linha["RECORD_TYPE"].to_s.strip.presence || linha["DESCRIPTION"].to_s.strip

        valor.downcase
      end

      # Só os campos que classificam, com a descrição encurtada: o objetivo é
      # montar o de-para, não copiar o extrato para dentro do log.
      def combinacoes(tabela)
        tabela
          .map { |linha| [ linha["BUSINESS_UNIT"], linha["SUB_UNIT"], linha["DESCRIPTION"].to_s[0, 40] ] }
          .tally
          .sort_by { |_, quantas| -quantas }
          .first(15)
          .map { |(unidade, sub, descricao), quantas| "#{unidade} | #{sub} | #{descricao} -> #{quantas}" }
          .join(" ;; ")
      end

      # Toda leitura deixa registrado o que o relatório tinha DENTRO.
      #
      # A contagem por tipo é o que responde "tem movimentação mas não tem
      # saldo?" — a pergunta que aparece quando a conta claramente vendeu e a
      # conferência de saldo diz que não veio nada. Saldo vem das linhas de
      # resumo, que são registros à parte da movimentação; ter uma não implica
      # ter a outra.
      def relatar(eventos)
        return if @lidas.zero?

        com_pedido = eventos.count { |evento| evento[:external_order_id].present? }

        Rails.logger.info(
          "[ReleaseEvents] #{@lidas} linha(s): #{eventos.size} lançamento(s), " \
          "#{@internos.values.sum} movimento(s) interno(s) fora do razão, " \
          "saldos #{@saldos.any? ? @saldos.keys.join('/') : 'AUSENTES'}. " \
          "Tipos: #{@tipos.inspect}. " \
          "Com pedido: #{com_pedido}/#{eventos.size}. " \
          "Colunas preenchidas: #{preenchimento.inspect}"
        )

        avisar_se_mudo(eventos)
      end

      # Quantas linhas trouxeram valor em cada coluna que poderia identificar o
      # pedido. É o que responde "por que o lançamento não tem pedido?" sem
      # abrir o arquivo: ou a coluna existe e vem vazia, ou o número está em
      # outra. Contagens, nunca os valores.
      def preenchimento
        @preenchimento ||= Hash.new(0)
      end

      def contar_preenchimento(linha)
        IDENTIFICADORES.each do |coluna|
          next if linha[coluna].to_s.strip.empty?

          preenchimento[coluna] += 1
        end
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

        CSV.parse(csv,
                  col_sep: separador,
                  headers: true,
                  header_converters: ->(h) { h.to_s.strip.upcase })
      rescue CSV::MalformedCSVError => e
        raise ArgumentError, "Relatório de liberações ilegível: #{e.message}"
      end

      # O relatório real do Mercado Pago vem separado por PONTO E VÍRGULA. Com
      # vírgula, o cabeçalho inteiro virava UMA coluna chamada
      # "DATE;SOURCE_ID;DESCRIPTION;..." — nenhuma coluna era encontrada, todo
      # valor dava nil, e as 41 linhas produziram zero lançamentos em silêncio.
      #
      # Decidido pelo cabeçalho e não por configuração: é ele que prova qual é,
      # e o formato pode mudar sem avisar.
      def separador
        cabecalho = csv.lines.first.to_s

        SEPARADORES.max_by { |candidato| cabecalho.count(candidato) }
      end

      def eventos_de(linha)
        tipo = tipo_da(linha)

        @tipos[tipo.presence || "(vazio)"] += 1

        contar_preenchimento(linha)

        if RESUMO.include?(tipo)
          registrar_saldo(tipo, linha)

          return []
        end

        return [saque(linha)] if SAQUE.include?(tipo)

        return disputa(linha, DISPUTAS[tipo]) if DISPUTAS.key?(tipo)

        return venda_com_deducoes(linha) if VENDA.include?(tipo)

        # Movimento interno entra na contagem própria, e não em `ignorados`:
        # ignorado é o que não sabemos tratar, e estes a gente sabe — a decisão
        # é deixá-los de fora de propósito.
        if MOVIMENTO_INTERNO.include?(tipo)
          @internos[tipo] += 1

          return []
        end

        # Tudo o mais é contado e NÃO importado.
        #
        # O ramo de venda já foi o destino padrão do que não fosse reconhecido,
        # e é exatamente assim que um saque vira receita. Tipo desconhecido
        # agora aparece na contagem e fica de fora do razão.
        @ignorados[tipo.presence || "(vazio)"] += 1

        []
      end

      def venda_com_deducoes(linha)
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
        pedido = pedido_de(linha)

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
          # Este relatório é o de LIBERAÇÕES: cada linha é dinheiro que já
          # afetou o saldo. Não há nada pendente aqui — pendente é o que ainda
          # vai cair, e isso vive em receivable_units, não no razão.
          status: :settled,
          settled_at: ocorrido,
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
                [pedido_de(linha), linha["DATE"].to_s.strip].compact_blank.join("-")

        "MLREL-#{chave}-#{sufixo}"
      end

      # No arquivo real a coluna do pedido chama PURCHASE_ID; ORDER_ID é o nome
      # da documentação. É este campo que liga o repasse à nota fiscal do Tiny,
      # então vale procurar nos dois.
      def pedido_de(linha)
        linha["ORDER_ID"].to_s.strip.presence || linha["PURCHASE_ID"].to_s.strip.presence
      end

      # Devolver zero para o que não soube ler é a forma mais silenciosa de
      # errar dinheiro: some do razão sem deixar rastro. O arquivo é separado
      # por ponto e vírgula, o que costuma andar junto com decimal por VÍRGULA
      # ("1.234,56") — e `BigDecimal("1.234,56")` levanta. Cada valor viraria
      # zero, a importação diria que trouxe tudo, e os lançamentos seriam de
      # R$ 0,00.
      def decimal(valor)
        texto = valor.to_s.strip

        return BigDecimal("0") if texto.empty?

        BigDecimal(normalizar_numero(texto))
      rescue ArgumentError
        raise ValorIlegivel,
              "Valor numérico ilegível no relatório de liberações: #{texto.inspect}. " \
              "Importar com ele valendo zero apagaria dinheiro do razão em silêncio."
      end

      # Decide pelo ÚLTIMO separador, que é o decimal em qualquer das duas
      # convenções: "1.234,56" (pt-BR) e "1,234.56" (en) são desempatados por
      # qual vem por último.
      def normalizar_numero(texto)
        limpo = texto.delete(" ")

        return limpo unless limpo.include?(",")

        if limpo.rindex(",").to_i > limpo.rindex(".").to_i
          limpo.delete(".").tr(",", ".")
        else
          limpo.delete(",")
        end
      end

      def data(valor)
        Time.zone.parse(valor.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
