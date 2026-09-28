module Conciliacao
  # O que separa o BRUTO que o marketplace pagou do TÍTULO que o OMIE tem, para uma
  # nota e as vendas dela dentro de um repasse.
  #
  # Existe num lugar só porque as sondas de diagnóstico já divergiram do motor duas
  # vezes nesta base, e nas duas eu li a divergência como achado: a primeira versão do
  # `rateio_do_pacote` subtraía parcelamento onde o motor não subtraía, e todo delta
  # saía igual ao parcelamento. Sonda que refaz a conta por conta própria mede a
  # suposição de quem a escreveu.
  #
  # Aqui a conta é feita uma vez. O motor soma os resultados; a sonda os imprime.
  class ComposicaoDaVenda
    # A folga de um decimo: a fração é divisão e o rateio de pacote não é exato.
    TOLERANCIA = BigDecimal("0.10")

    Resultado = Struct.new(
      :produtos, :bruto, :frete, :desconto, :parcelamento, :cupom,
      :sobra, :somado_ao_bruto, :hipotese, :ajuste_do_titulo, :valor_do_pedido,
      keyword_init: true
    ) do
      # O bruto trazido para a mercadoria: é ele que se compara com o título ajustado.
      def interno = bruto - somado_ao_bruto

      # Quanto somar ao título do OMIE para trazê-lo à mercadoria.
      #
      # O título vale a nota inteira, e a nota é `produtos + frete − desconto`. Somar o
      # desconto e subtrair o frete devolve `produtos`, que é o que o bruto mede.
      def esperado_para(titulo, fracao) = ((titulo + ajuste_do_titulo) * fracao).round(2)

      def delta_para(titulo, fracao) = (interno - esperado_para(titulo, fracao)).round(2)
    end

    # `vendas` são os recebíveis daquela nota DENTRO deste repasse; `linhas` é o mapa
    # external_id → linha do relatório; `fracao` é a parte da nota que este repasse
    # liquidou.
    def self.para(nota:, vendas:, linhas:, fracao:)
      fiscal = nota.metadata.to_h["fiscal"].to_h

      produtos = fiscal["valor_produtos"].to_d

      frete = fiscal["valor_frete"].to_d

      desconto = fiscal["valor_desconto"].to_d

      bruto = vendas.sum(BigDecimal("0")) { |u| u.gross_amount.to_d }

      parcelamento = soma(vendas, linhas, "FINANCING_FEE_AMOUNT")

      cupom = soma(vendas, linhas, "COUPON_AMOUNT")

      sobra = produtos.positive? ? (bruto - (produtos * fracao)) : BigDecimal("0")

      # O que o MARKETPLACE diz que esta venda vale, rateado como o resto.
      #
      # `Order#total_amount` vem da API de pedidos e é escrito só pela ingestão do
      # Mercado Livre — o Tiny cria pedido sem valor. Então confrontá-lo com a nota é
      # confrontar duas fontes independentes, e não a nota consigo mesma.
      do_pedido = (vendas.sum(BigDecimal("0")) { |u| u.order&.total_amount.to_d } * fracao).round(2)

      hipotese, somado = testar(sobra, parcelamento, frete * fracao, bruto, do_pedido)

      Resultado.new(
        produtos: produtos, bruto: bruto, frete: frete, desconto: desconto,
        parcelamento: parcelamento, cupom: cupom, sobra: sobra.round(2),
        somado_ao_bruto: somado, hipotese: hipotese, valor_do_pedido: do_pedido,
        ajuste_do_titulo: ajuste(nota, produtos, frete, desconto)
      )
    end

    # Quanto somar ao título para trazê-lo à MERCADORIA.
    #
    # `produtos − total da nota`, e não `desconto − frete`. As duas são a MESMA conta
    # sempre que a nota fecha com ela mesma, porque aí `total = produtos + frete −
    # desconto`. A diferença aparece só quando a nota NÃO fecha — e aí a primeira está
    # certa e a segunda erra exatamente pelo que falta.
    #
    # Medido em 2026-09-28 nas 39 notas do balde "delta sem causa nomeada", R$ 230,32:
    # em 39 de 39 o total da nota difere de `produtos + frete − desconto`, e em 39 de 39
    # o título do OMIE está igual ao total da nota. Duas formas:
    #
    #   34 notas · total = produtos − 3,00 ou − 4,00, sem desconto declarado
    #    5 notas · total = produtos + 19,99 / 16,99 / 25,99, sem frete declarado
    #
    # A primeira é abatimento que o emissor deu e não pôs no campo de desconto; a segunda
    # é o juro do parcelamento embutido no total e ausente de produtos. Nos dois casos o
    # título espelha o total, então é do total que se desce até a mercadoria.
    #
    # Não é circular: o esperado sai do TÍTULO, que vem do OMIE, e só o ajuste vem da
    # nota. Quando o título discorda do total da nota — título duplicado é o caso medido —
    # a diferença continua aparecendo, porque o ajuste não a cancela.
    #
    # Sem `valor_produtos` não há mercadoria a que descer, e aí a conta antiga é o melhor
    # que existe: usar `−total` zeraria o esperado e inventaria uma diferença do tamanho
    # da nota.
    def self.ajuste(nota, produtos, frete, desconto)
      return desconto - frete unless produtos.positive?

      total = nota.total_amount.to_d

      return desconto - frete unless total.positive?

      produtos - total
    end

    # Hipóteses NOMEADAS contra a sobra medida, em vez de ajustar um número até fechar.
    #
    # A soma primeiro: se ela bate, testar as parcelas isoladas antes faria casar com uma
    # e deixar a outra de fora. Sobra que não bate com nenhuma NÃO é subtraída — fica
    # como diferença real, porque subtrair a sobra inteira fecharia tudo por construção.
    def self.testar(sobra, parcelamento, frete, bruto, do_pedido)
      return [ :nada_somado, BigDecimal("0") ] unless sobra.positive?

      candidatas = [
        [ :parcelamento_e_frete, parcelamento + frete ],
        [ :frete, frete ],
        [ :parcelamento, parcelamento ]
      ]

      achada = candidatas.find { |_, valor| valor.positive? && (sobra - valor).abs <= TOLERANCIA }

      achada || ultimo_recurso(bruto, do_pedido)
    end

    # O valor do pedido, quando nenhuma hipótese nomeada fecha.
    #
    # Medido em 2026-09-28 nas 169 notas do balde `sobra_sem_hipotese`: em 38 de 40
    # consultas ao Mercado Livre a sobra é exatamente `bruto − transaction_amount`, e
    # naqueles 38 o `transaction_amount` é igual ao `valor_produtos` da nota **e** ao
    # `total_amount` do pedido. O `GROSS_AMOUNT` é o que o COMPRADOR pagou — mercadoria
    # mais o juro do parcelamento que ele escolheu —, e esse juro nunca foi receita do
    # vendedor, então a nota não o documenta e não deveria.
    #
    # ÚLTIMO recurso, e não primeiro, porque isso foi medido e não suposto. Os três
    # regimes, sobre as 3.718 notas comparadas:
    #
    #   (a) hoje                       3514 fecham · soma |deltas| R$  3118,32
    #   (b) pedido no último recurso    3674 fecham · soma |deltas| R$   983,69
    #   (c) pedido primeiro             3615 fecham · soma |deltas| R$ 11211,94
    #
    # Trocar a base por inteiro PIORA: frete e parcelamento explicam de verdade boa parte
    # das vendas, e o valor do pedido discorda da nota em 64 das 3.718. Nessas 64 a
    # discordância é diferença REAL — o marketplace e a nota dizendo valores diferentes
    # para a mesma venda — e ela continua aparecendo, porque é o que a coluna existe para
    # mostrar.
    #
    # Sem valor no pedido não há último recurso: subtrair `bruto − 0` zeraria o lado
    # interno e inventaria uma diferença do tamanho do repasse.
    def self.ultimo_recurso(bruto, do_pedido)
      return [ :sobra_sem_hipotese, BigDecimal("0") ] unless do_pedido.positive?

      excedente = bruto - do_pedido

      return [ :sobra_sem_hipotese, BigDecimal("0") ] unless excedente.positive?

      [ :valor_do_pedido, excedente ]
    end

    def self.soma(vendas, linhas, coluna)
      vendas.sum(BigDecimal("0")) do |unidade|
        linhas[unidade.external_id].to_h[coluna].to_d.abs
      end
    end

    private_class_method :testar, :ultimo_recurso, :ajuste, :soma
  end
end
