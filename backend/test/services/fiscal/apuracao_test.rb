require "test_helper"

module Fiscal
  # A conciliação fiscal do Simples não é imposto por nota — é receita bruta do
  # mês segregada por tributação. Estes testes fixam as três decisões que
  # sustentam essa conta: o que entra na receita, o que conta como ST, e o que
  # NÃO é chutado para nenhum dos dois lados.
  class ApuracaoTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
      @pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PED-1")
    end

    def nota(numero:, valor:, mes: "2026-08", operacao: :sale, status: :issued,
             fiscal: nil, intermediador: "Mercado Livre")
      Invoice.create!(
        tenant: @tenant, order: @pedido, number: numero, series: "1",
        status: status, operation_type: operacao, total_amount: valor,
        issued_at: Date.parse("#{mes}-10"), external_id: "nf-#{numero}",
        metadata: {
          "intermediador" => { "nome" => intermediador },
          **(fiscal ? { "fiscal" => fiscal } : {})
        }
      )
    end

    def apurar(de: "2026-07-01", ate: "2026-09-30")
      Apuracao.new(tenant: @tenant, de: Date.parse(de), ate: Date.parse(ate)).call
    end

    def mes_de(resultado, mes) = resultado[:meses].find { |m| m[:mes] == mes }

    test "receita bruta soma as vendas do mês e ignora a cancelada" do
      nota(numero: "1", valor: 100, fiscal: { "valor_icms_st" => "0" })
      nota(numero: "2", valor: 250, fiscal: { "valor_icms_st" => "0" })
      nota(numero: "3", valor: 999, status: :cancelled, fiscal: { "valor_icms_st" => "0" })
      nota(numero: "4", valor: 70, mes: "2026-09", fiscal: { "valor_icms_st" => "0" })

      resultado = apurar

      assert_equal "350.0", mes_de(resultado, "2026-08")[:receita_bruta]
      assert_equal 2, mes_de(resultado, "2026-08")[:notas]
      assert_equal "70.0", mes_de(resultado, "2026-09")[:receita_bruta]
      assert_equal "420.0", resultado[:total][:receita_bruta]
    end

    # A devolução não diminui a receita BRUTA do mês — ela aparece à parte e sai
    # na líquida. Misturar as duas esconderia o que foi vendido.
    test "devolução sai da líquida e não da bruta" do
      nota(numero: "1", valor: 300, fiscal: { "valor_icms_st" => "0" })
      nota(numero: "2", valor: 50, operacao: :refund, fiscal: { "valor_icms_st" => "0" })

      agosto = mes_de(apurar, "2026-08")

      assert_equal "300.0", agosto[:receita_bruta]
      assert_equal 1, agosto[:devolucoes][:notas]
      assert_equal "50.0", agosto[:devolucoes][:valor]
      assert_equal "250.0", agosto[:receita_liquida]
    end

    # Dois sinais, duas fontes: o Tiny informa o VALOR do ICMS-ST, o Mercado
    # Livre informa o CSOSN por item. Os dois têm de cair no mesmo lado.
    test "ST reconhecida pelo valor do Tiny e pelo CSOSN do Mercado Livre" do
      nota(numero: "1", valor: 100, fiscal: { "valor_icms_st" => "12.30" })
      nota(numero: "2", valor: 200, fiscal: { "csosns" => [ "500" ] })
      nota(numero: "3", valor: 400, fiscal: { "csosns" => [ "102" ] })

      agosto = mes_de(apurar, "2026-08")

      assert_equal 2, agosto[:segregacao][:com_st][:notas]
      assert_equal "300.0", agosto[:segregacao][:com_st][:receita]
      assert_equal 1, agosto[:segregacao][:sem_st][:notas]
      assert_equal "400.0", agosto[:segregacao][:sem_st][:receita]
      assert_equal "12.3", agosto[:impostos_na_nota][:icms_st]
    end

    # O ponto mais importante da apuração: nota sem detalhe fiscal não pode ser
    # contada como "sem ST". Ela não é nem uma coisa nem outra, e somá-la ao
    # lado errado muda a base que o contador declara.
    test "nota sem bloco fiscal fica indefinida, nunca como sem ST" do
      nota(numero: "1", valor: 100, fiscal: { "csosns" => [ "102" ] })
      nota(numero: "2", valor: 900)

      resultado = apurar

      agosto = mes_de(resultado, "2026-08")

      assert_equal 1, agosto[:segregacao][:sem_st][:notas]
      assert_equal 1, agosto[:segregacao][:indefinido][:notas]
      assert_equal "900.0", agosto[:segregacao][:indefinido][:receita]

      assert_equal 1, resultado[:cobertura][:sem_bloco_fiscal]
      assert_equal "900.0", resultado[:cobertura][:receita_sem_detalhe],
                   "a cobertura precisa falar em dinheiro: cem notas pequenas sem detalhe" \
                   " pesam menos que uma grande"
    end

    # CSOSN que não decide nada (900, "outros") não pode escolher um lado só
    # porque estava numa lista antes da outra.
    test "CSOSN 900 não decide e cai em indefinido" do
      nota(numero: "1", valor: 100, fiscal: { "csosns" => [ "900" ] })

      assert_equal 1, mes_de(apurar, "2026-08")[:segregacao][:indefinido][:notas]
    end

    test "receita por canal usa o intermediador e expõe o nome não mapeado" do
      nota(numero: "1", valor: 100, intermediador: "Mercado Livre", fiscal: { "csosns" => [ "102" ] })
      nota(numero: "2", valor: 300, intermediador: "Alma teen", fiscal: { "csosns" => [ "102" ] })

      canais = mes_de(apurar, "2026-08")[:por_canal]

      sem_canal = canais.find { |c| c[:canal].nil? }

      assert_equal "300.0", sem_canal[:receita]
      assert_equal "Sem canal mapeado", sem_canal[:rotulo]
      assert_equal [ "Alma teen" ], sem_canal[:intermediadores],
                   "sem o nome, ninguém sabe o que mapear"

      ml = canais.find { |c| c[:canal] == "mercado_livre" }

      assert_equal "100.0", ml[:receita]
      assert_equal "Mercado Livre", ml[:rotulo]
    end

    # O mapa da empresa vence o padrão: "Alma teen" é venda de balcão do
    # cliente, e isso ninguém adivinha pelo nome.
    test "canal mapeado pela empresa é respeitado" do
      Fiscal::Tiny::Canal.mapear!(@tenant, "Alma teen", Fiscal::Tiny::Canal::PROPRIA)

      nota(numero: "1", valor: 300, intermediador: "Alma teen", fiscal: { "csosns" => [ "102" ] })

      canal = mes_de(apurar, "2026-08")[:por_canal].first

      assert_equal "loja_propria", canal[:canal]
      assert_equal "Venda própria — não é marketplace", canal[:rotulo]
    end

    # A pergunta literal do usuário — "quais impostos o marketplace pagou por
    # mim" — tem de ter resposta medida, e ela vem do EXTRATO, não da nota.
    test "o retido pelo marketplace vem do extrato" do
      lancamento = FinancialEntry.create!(
        tenant: @tenant, platform_account: @conta, external_id: "MLREL-1",
        amount: 100, net_amount: 100, occurred_at: Date.parse("2026-08-10"),
        entry_type: :sale, direction: :credit, raw_payload: { "TAXES_AMOUNT" => "-3.50" }
      )

      assert_equal "3.5", apurar[:retido_pelo_marketplace]

      lancamento.update!(raw_payload: { "TAXES_AMOUNT" => "" })

      assert_equal "0.0", apurar[:retido_pelo_marketplace],
                   "string vazia não é zero em ::numeric — precisa de NULLIF"
    end

    # O produto terá cliente de Regime Normal, e para ele a conta é o OPOSTO:
    # a nota carrega imposto e é a soma dele que importa. O regime tem de ser
    # dimensão, não suposição.
    test "regime normal apura por imposto e o simples por receita" do
      nota(numero: "1", valor: 100, fiscal: { "regime_tributario" => "1", "csosns" => [ "102" ] })

      assert_equal :receita, mes_de(apurar, "2026-08")[:base]

      nota(numero: "2", valor: 500, mes: "2026-09",
           fiscal: { "regime_tributario" => "3", "valor_icms" => "90.00",
                     "base_icms" => "500.00", "csts" => [ "00" ] })

      setembro = mes_de(apurar, "2026-09")

      assert_equal :imposto, setembro[:base]
      assert_equal "90.0", setembro[:impostos_na_nota][:icms]
      assert_equal "500.0", setembro[:impostos_na_nota][:base_icms]
      assert_equal 1, setembro[:segregacao][:sem_st][:notas], "CST 00 não tem ST"
    end

    # Virada de regime no meio do período é caso real, e somar as duas apurações
    # num número só seria inventar.
    test "mês com os dois regimes fica mista" do
      nota(numero: "1", valor: 100, fiscal: { "regime_tributario" => "1", "csosns" => [ "102" ] })
      nota(numero: "2", valor: 200, fiscal: { "regime_tributario" => "3", "csts" => [ "00" ] })

      agosto = mes_de(apurar, "2026-08")

      assert_equal :mista, agosto[:base]
      assert_equal 2, agosto[:por_regime].size
      assert_equal [ :imposto, :receita ], agosto[:por_regime].map { |r| r[:base] }.sort
    end

    # "1" no Tiny e "simples" no Mercado Livre são o mesmo regime; quem lê a
    # apuração não pode precisar saber de qual API a nota veio.
    test "o regime é normalizado entre as fontes" do
      nota(numero: "1", valor: 100, fiscal: { "regime_tributario" => "1", "csosns" => [ "102" ] })
      nota(numero: "2", valor: 200, fiscal: { "regime_tributario" => "simples", "csosns" => [ "102" ] })

      regimes = apurar[:regimes]

      assert_equal 1, regimes.size
      assert_equal :simples, regimes.first[:regime]
      assert_equal 2, regimes.first[:notas]
    end

    # Regime desconhecido NÃO vira Simples: apurar uma nota de Regime Normal
    # como Simples esconderia o imposto devido.
    test "regime não reconhecido fica à parte, com o valor cru" do
      nota(numero: "1", valor: 100, fiscal: { "regime_tributario" => "lucro arbitrado" })

      regime = apurar[:regimes].first

      assert_nil regime[:regime]
      assert_nil regime[:base]
      assert_equal "Regime não identificado", regime[:rotulo]
      assert_equal [ "lucro arbitrado" ], regime[:valores_crus],
                   "sem o valor cru ninguém sabe o que mapear"
    end

    test "CST de substituição conta como ST" do
      nota(numero: "1", valor: 100, fiscal: { "regime_tributario" => "3", "csts" => [ "60" ] })

      assert_equal 1, mes_de(apurar, "2026-08")[:segregacao][:com_st][:notas]
    end

    # No Simples a RBT12 decide alíquota e sublimite. O risco aqui não é errar a
    # soma: é exibir um acumulado PARCIAL como se fosse o ano fechado, dizendo
    # "longe do teto" quando a conta nem cobriu doze meses.
    test "RBT12 diz quando está incompleta" do
      nota(numero: "1", valor: 300_000, mes: "2026-08", fiscal: { "csosns" => [ "102" ] })
      nota(numero: "2", valor: 200_000, mes: "2026-09", fiscal: { "csosns" => [ "102" ] })

      rbt12 = apurar(de: "2026-07-01", ate: "2026-09-30")[:rbt12]

      assert_equal "500000.0", rbt12[:receita]
      assert_not rbt12[:completo], "só há 2 meses de notas: não pode passar por ano fechado"
      assert_equal 2, rbt12[:meses_com_dados]
      assert_equal "3000000.0", rbt12[:projecao_anual], "500 mil em 2 meses projeta 3 milhões"
    end

    # A janela da TELA é escolha de quem olha; a RBT12 é definida por lei como 12
    # meses. Deixar as duas coincidirem por acidente esconde o erro de alguém
    # filtrar um trimestre e ler o número como anual.
    test "RBT12 não depende da janela pedida" do
      nota(numero: "1", valor: 100, mes: "2026-03", fiscal: { "csosns" => [ "102" ] })
      nota(numero: "2", valor: 900, mes: "2026-09", fiscal: { "csosns" => [ "102" ] })

      resultado = apurar(de: "2026-09-01", ate: "2026-09-30")

      assert_equal "900.0", resultado[:total][:receita_bruta], "a tela pediu só setembro"
      assert_equal "1000.0", resultado[:rbt12][:receita], "a RBT12 olha doze meses de todo jeito"
    end

    test "RBT12 desconta devolução e aponta a posição no teto" do
      nota(numero: "1", valor: 3_700_000, mes: "2026-09", fiscal: { "csosns" => [ "102" ] })
      nota(numero: "2", valor: 100_000, mes: "2026-09", operacao: :refund, fiscal: { "csosns" => [ "102" ] })

      rbt12 = apurar(de: "2026-09-01", ate: "2026-09-30")[:rbt12]

      assert_equal "3600000.0", rbt12[:receita]
      assert_equal "100.0", rbt12[:percentual_do_sublimite]
      assert_equal "75.0", rbt12[:percentual_do_teto]
    end

    test "fora da janela não entra" do
      nota(numero: "1", valor: 100, mes: "2026-06", fiscal: { "csosns" => [ "102" ] })

      resultado = apurar(de: "2026-07-01", ate: "2026-09-30")

      assert_equal 0, resultado[:total][:notas]
      assert_empty resultado[:meses]
    end
  end
end
