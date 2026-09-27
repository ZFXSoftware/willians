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
      :sobra, :somado_ao_bruto, :hipotese, :ajuste_do_titulo,
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

      hipotese, somado = testar(sobra, parcelamento, frete * fracao)

      Resultado.new(
        produtos: produtos, bruto: bruto, frete: frete, desconto: desconto,
        parcelamento: parcelamento, cupom: cupom, sobra: sobra.round(2),
        somado_ao_bruto: somado, hipotese: hipotese,
        # SÓ o desconto da nota. O cupom do relatório não ajusta o título: medido em 846
        # vendas com cupom, 756 têm `bruto == produtos` (a nota não abateu) e ZERO têm
        # `bruto − cupom == produtos`.
        ajuste_do_titulo: desconto - frete
      )
    end

    # Hipóteses NOMEADAS contra a sobra medida, em vez de ajustar um número até fechar.
    #
    # A soma primeiro: se ela bate, testar as parcelas isoladas antes faria casar com uma
    # e deixar a outra de fora. Sobra que não bate com nenhuma NÃO é subtraída — fica
    # como diferença real, porque subtrair a sobra inteira fecharia tudo por construção.
    def self.testar(sobra, parcelamento, frete)
      return [ :nada_somado, BigDecimal("0") ] unless sobra.positive?

      candidatas = [
        [ :parcelamento_e_frete, parcelamento + frete ],
        [ :frete, frete ],
        [ :parcelamento, parcelamento ]
      ]

      achada = candidatas.find { |_, valor| valor.positive? && (sobra - valor).abs <= TOLERANCIA }

      achada || [ :sobra_sem_hipotese, BigDecimal("0") ]
    end

    def self.soma(vendas, linhas, coluna)
      vendas.sum(BigDecimal("0")) do |unidade|
        linhas[unidade.external_id].to_h[coluna].to_d.abs
      end
    end

    private_class_method :testar, :soma
  end
end
