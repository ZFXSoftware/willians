require "test_helper"

module Financeiro
  # Briefing 2.7. Pagamento de NF feito direto na plataforma precisa ser
  # baixado no OMIE. Espelho da baixa de recebimentos, com a mesma regra dura:
  # divergência não é baixada.
  class BaixaDePagamentosTest < ActiveSupport::TestCase
    setup do
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant, metadata: { "omie_conta_corrente_id" => "6455415244" })
    end

    def pagamento(valor: 1359, numero: nil, com_nota: true)
      pedido = criar_pedido(tenant: @tenant, conta: @conta)

      nota = com_nota ? criar_nota(tenant: @tenant, pedido: pedido, numero: numero || "0003337372", valor: valor) : nil

      criar_lancamento(tenant: @tenant, conta: @conta, tipo: :payment, direcao: :debit,
                       valor: valor, pedido: pedido, nota: nota, ocorrido_em: 2.days.ago)
    end

    def indice(codigo, numero, valor)
      TitulosFalsos.indice(TitulosFalsos.titulo(codigo: codigo, numero: numero, valor: valor))
    end

    def rodar(client:, titulos:, **opcoes)
      BaixaDePagamentos.new(tenant: @tenant, client: client, titulos: titulos, **opcoes).call
    end

    test "simula quando a escrita está bloqueada" do
      pagamento
      espiao = OmieEspiao.new

      resultado = com_env("OMIE_ALLOW_WRITES" => nil) do
        rodar(client: espiao, titulos: indice(901, "3337372", 1359))
      end

      assert resultado[:resumo][:simulacao]
      assert_empty espiao.chamadas
      assert_equal 1, resultado[:resumo][:baixaria]
    end

    test "baixa o título a pagar quando o valor confere" do
      pagamento
      espiao = OmieEspiao.new

      rodar(client: espiao, titulos: indice(901, "3337372", 1359), dry_run: false)

      chamada = espiao.chamadas.first

      assert_equal "financas/contapagar/", chamada[:endpoint]
      assert_equal "LancarPagamento", chamada[:call], "no contas a pagar a baixa é LancarPagamento"
      assert_equal 901, chamada[:params][:codigo_lancamento]
      assert_equal 1359.0, chamada[:params][:valor]
      assert_equal 6_455_415_244, chamada[:params][:codigo_conta_corrente]
    end

    test "divergência bloqueia a baixa e abre um caso" do
      lancamento = pagamento(valor: 1359)
      espiao = OmieEspiao.new

      resultado = rodar(client: espiao, titulos: indice(902, "3337372", 1200), dry_run: false)

      assert_equal 1, resultado[:resumo][:divergente]
      assert_empty espiao.chamadas, "não pode baixar valor que não bate"

      divergencia = DivergenceReport.find_by!(tenant_id: @tenant.id, financial_entry_id: lancamento.id)

      assert_equal "valor_divergente_no_pagamento", divergencia.divergence_type
      assert_equal BigDecimal("1200"), divergencia.expected_amount
      assert_equal BigDecimal("1359"), divergencia.received_amount
    end

    test "número da nota também pode vir do documento do lançamento" do
      criar_lancamento(tenant: @tenant, conta: @conta, tipo: :payment, direcao: :debit,
                       valor: 500, ocorrido_em: 2.days.ago)
        .update!(metadata: { "numero_documento" => "0000778899" })

      espiao = OmieEspiao.new
      rodar(client: espiao, titulos: indice(903, "778899", 500), dry_run: false)

      assert_equal 903, espiao.chamadas.first[:params][:codigo_lancamento]
    end

    test "casos sem caminho são contados, não ignorados" do
      pagamento(com_nota: false)

      resumo = rodar(client: OmieEspiao.new, titulos: {})[:resumo]

      assert_equal 1, resumo[:sem_nota]

      pagamento
      assert_equal 1, rodar(client: OmieEspiao.new, titulos: {})[:resumo][:titulo_nao_encontrado]
    end

    test "não baixa duas vezes o mesmo pagamento" do
      pagamento

      rodar(client: OmieEspiao.new, titulos: indice(901, "3337372", 1359), dry_run: false)

      segunda = OmieEspiao.new
      rodar(client: segunda, titulos: indice(901, "3337372", 1359), dry_run: false)

      assert_empty segunda.chamadas
    end

    test "recebimento não é confundido com pagamento" do
      criar_lancamento(tenant: @tenant, conta: @conta, tipo: :sale, direcao: :credit,
                       valor: 100, ocorrido_em: 2.days.ago)

      espiao = OmieEspiao.new
      rodar(client: espiao, titulos: indice(901, "3337372", 1359), dry_run: false)

      assert_empty espiao.chamadas
    end
  end
end
