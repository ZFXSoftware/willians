require "test_helper"

module Conciliacao
  # Saque de saldo acumulado não se confere contra nota fiscal.
  #
  # Dois dos 36 repasses do cliente (#33 e #44) não têm recebível nenhum: os dois
  # caem no MESMO DIA de outro saque que consumiu a janela antes deles. O motor
  # procurava título no OMIE, não achava, marcava `manual_review` e lançava o valor
  # cheio como diferença — R$ 3.602,00, metade da diferença de toda a empresa,
  # mandando alguém caçar uma nota fiscal que não deveria existir.
  #
  # O que dá o direito de dizer "não há o que comparar" é o SALDO: `BALANCE_AMOUNT`
  # é o saldo corrente calculado pelo próprio Mercado Livre, e não-negativo depois
  # da saída significa que o dinheiro que saiu estava lá. Sem essa condição a regra
  # seria tautologia — "não achei venda, logo está certo" fecharia por construção
  # todo repasse cuja ingestão falhou.
  class SaqueDeSaldoTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
    end

    # Um saque: linha `payout` do relatório, nenhum recebível alocado.
    def saque(valor: 3102.00, saldo: "0.24", descricao: "payout", pago_em: Time.current - 1.day)
      lancamento = criar_lancamento(
        tenant: @tenant, conta: @conta, tipo: :settlement, direcao: :debit,
        valor: valor, external_id: "MLREL-#{SecureRandom.hex(4)}-PAYOUT"
      )

      lancamento.update!(raw_payload: {
        "DESCRIPTION" => descricao,
        "RECORD_TYPE" => "release",
        "BALANCE_AMOUNT" => saldo,
        "NET_DEBIT_AMOUNT" => valor.to_s,
        "GROSS_AMOUNT" => (-valor).to_s
      })

      # `bruto == liquido == valor do extrato`: é o que o PayoutEngine grava quando
      # não encontra recebível nenhum para o repasse.
      criar_repasse(tenant: @tenant, conta: @conta, bruto: valor, liquido: valor,
                    pago_em: pago_em, lancamento: lancamento)
    end

    def conciliar
      ConciliacaoEngine.new(
        tenant: @tenant, platform_account: @conta,
        start_date: Date.current - 10, end_date: Date.current,
        omie_totals: { "500" => BigDecimal("178.65") }
      ).call

      ConciliacaoRegistro.where(tenant_id: @tenant.id).order(:id).last
    end

    test "saque sem venda na janela não é divergência nem diferença" do
      saque(valor: 3102.00, saldo: "0.24")

      registro = conciliar

      assert_equal "saque", registro.status
      assert_equal BigDecimal("0"), registro.diferenca.to_d

      # O valor é o que SAIU, e continua visível: a tela precisa mostrar que
      # R$ 3.102,00 deixaram a conta.
      assert_equal BigDecimal("3102"), registro.valor.to_d
    end

    test "o saque não abre divergência para alguém investigar" do
      saque

      conciliar

      assert_equal 0, DivergenceReport.where(tenant_id: @tenant.id, status: :open).count
    end

    # A condição que impede a tautologia: saldo NEGATIVO depois da saída significa
    # que faltam créditos do nosso lado — a ingestão perdeu vendas — e aí pedir
    # revisão está certo.
    test "saldo negativo depois do saque continua pedindo revisão" do
      saque(valor: 3102.00, saldo: "-500.00")

      registro = conciliar

      assert_equal "manual_review", registro.status
      refute_equal BigDecimal("0"), registro.diferenca.to_d
    end

    # Sem a coluna do saldo não há evidência, e sem evidência não se afirma nada.
    test "saldo ausente no relatório continua pedindo revisão" do
      saque(valor: 3102.00, saldo: "")

      registro = conciliar

      assert_equal "manual_review", registro.status
    end

    # A linha tem que ser de SAÍDA de dinheiro. Repasse sem recebível cuja linha de
    # origem é uma venda é outro problema — vínculo perdido —, e silenciá-lo aqui
    # esconderia exatamente o que este status não pode esconder.
    test "linha que não é saque não vira saque, mesmo sem recebível" do
      saque(valor: 3102.00, saldo: "0.24", descricao: "payment")

      registro = conciliar

      assert_equal "manual_review", registro.status
    end

    # O irmão do mesmo dia é a CAUSA de a janela estar vazia, e é o que faz alguém
    # entender a tela sem abrir um script.
    test "a observação nomeia o saque irmão do mesmo dia" do
      dia = Time.current - 1.day

      primeiro = saque(valor: 500.00, saldo: "10.00", pago_em: dia)

      saque(valor: 3102.00, saldo: "0.24", pago_em: dia + 1.hour)

      registro = conciliar

      assert_includes registro.observacao, "##{primeiro.id}"
      assert_includes registro.observacao, "Saque de saldo acumulado"
      assert_includes registro.observacao, "0.24"
    end

    # O contador alimenta `divergent_entries` da execução. Um saque contado como
    # `nao_encontrado` voltaria a aparecer como divergência no resumo, mesmo com o
    # status certo gravado no registro.
    test "o saque fica fora da contagem de divergências da execução" do
      saque

      ConciliacaoEngine.new(
        tenant: @tenant, platform_account: @conta,
        start_date: Date.current - 10, end_date: Date.current,
        omie_totals: {}
      ).call

      execucao = ConciliationRun.where(tenant_id: @tenant.id).order(:id).last

      assert_equal 0, execucao.divergent_entries
      assert_equal 1, execucao.metadata["saques"]
    end
  end
end
