require "test_helper"

module Fiscal
  # O Tiny é quem emite as NF-e do cliente. O campo numero_ecommerce é o elo
  # entre o pedido do marketplace e a nota — e o número da nota é o que casa
  # com o título no OMIE. Sem essa corrente, não há baixa automática.
  class TinyTest < ActiveSupport::TestCase
    T = Fiscal::Tiny

    # Formato real da API 2.0: envelope `retorno`, itens embrulhados.
    PAGINA1 = {
      "retorno" => {
        "status_processamento" => "3", "status" => "OK", "pagina" => 1, "numero_paginas" => 2,
        "notas_fiscais" => [
          { "nota_fiscal" => { "id" => "9001", "numero" => "251372", "serie" => "1",
                               "tipo" => "S", "data_emissao" => "05/08/2026",
                               "chave_acesso" => "35260745896022000110550040001085131479638800",
                               "valor" => "119.99", "numero_ecommerce" => "PED-ML-001",
                               "situacao" => "6", "descricao_situacao" => "Autorizada" } },
          { "nota_fiscal" => { "id" => "9002", "numero" => "251373", "serie" => "1",
                               "tipo" => "S", "data_emissao" => "05/08/2026",
                               "chave_acesso" => "352607458960220001105500400010851314796388XX",
                               "valor" => "50.00", "numero_ecommerce" => "PED-SEM-PEDIDO",
                               "situacao" => "8", "descricao_situacao" => "Cancelada" } }
        ]
      }
    }.freeze

    PAGINA2 = {
      "retorno" => {
        "status_processamento" => "3", "status" => "OK", "pagina" => 2, "numero_paginas" => 2,
        "notas_fiscais" => [
          { "nota_fiscal" => { "id" => "9003", "numero" => "251374", "serie" => "1",
                               "tipo" => "S", "data_emissao" => "06/08/2026", "chave_acesso" => "",
                               "valor" => "80.00", "numero_ecommerce" => "",
                               "situacao" => "6", "descricao_situacao" => "Autorizada" } }
        ]
      }
    }.freeze

    # Nota de ENTRADA: a devolução do mesmo pedido, com id e número próprios.
    PAGINA_DEVOLUCAO = {
      "retorno" => {
        "status_processamento" => "3", "status" => "OK", "pagina" => 1, "numero_paginas" => 1,
        "notas_fiscais" => [
          { "nota_fiscal" => { "id" => "9500", "numero" => "700001", "serie" => "1",
                               "tipo" => "E", "data_emissao" => "10/08/2026",
                               "chave_acesso" => "35260745896022000110550040001085131479999900",
                               "valor" => "119.99", "numero_ecommerce" => "PED-ML-001",
                               "situacao" => "6", "descricao_situacao" => "Autorizada" } }
        ]
      }
    }.freeze

    VAZIO = {
      "retorno" => { "status_processamento" => "3", "status" => "Erro",
                     "erros" => [{ "erro" => "A consulta não retornou registros" }] }
    }.freeze

    ERRO_TOKEN = {
      "retorno" => { "status_processamento" => "1", "status" => "Erro", "codigo_erro" => "1",
                     "erros" => [{ "erro" => "Token inválido ou não informado" }] }
    }.freeze

    DE = Date.new(2026, 8, 1)

    ATE = Date.new(2026, 8, 31)

    # Dublê no nível do HTTP, de propósito: assim o parsing real do envelope do
    # Tiny fica exercitado, e não só a nossa normalização.
    class HttpFalso
      Resposta = Struct.new(:body, :code)

      attr_reader :chamadas

      def initialize(*paginas)
        @paginas = paginas
        @chamadas = []
      end

      def call(corpo)
        @chamadas << corpo

        Resposta.new((@paginas[(corpo[:pagina] || 1).to_i - 1] || VAZIO).to_json, "200")
      end
    end

    class ClienteEspiao < Fiscal::Tiny::V2Client
      def initialize(http)
        @http = http

        super(token: "TOKEN-TESTE")
      end

      private

      def executar(_uri, corpo) = @http.call(corpo)
    end

    def ler(*paginas, http: nil)
      http ||= HttpFalso.new(*paginas)

      [T::Reader.new(client: ClienteEspiao.new(http)).notas_fiscais(start_date: DE, end_date: ATE), http]
    end

    # ------------------------------------------------------------ leitura da API

    test "desembrulha o envelope e segue a paginação" do
      http = HttpFalso.new(PAGINA1, PAGINA2)
      notas, = ler(http: http)

      assert_equal 3, notas.size
      assert_equal [1, 2], http.chamadas.map { |c| c[:pagina] }
      assert_equal "TOKEN-TESTE", http.chamadas.first[:token]
      assert_equal "json", http.chamadas.first[:formato]
      assert_equal "01/08/2026", http.chamadas.first[:dataInicial]
      assert_equal "31/08/2026", http.chamadas.first[:dataFinal]
      assert_equal "S", http.chamadas.first[:tipoNota], "só nota de saída"
    end

    test "normaliza os campos que a conciliação precisa" do
      notas, = ler(PAGINA1, PAGINA2)
      nota = notas.first

      assert_equal "PED-ML-001", nota[:numero_ecommerce], "elo com o pedido do marketplace"
      assert_equal "251372", nota[:numero]
      assert_equal 44, nota[:chave_acesso].to_s.size
      assert_equal Date.new(2026, 8, 5), nota[:data_emissao]
      assert_equal BigDecimal("119.99"), nota[:valor]
    end

    test "consulta sem resultado devolve lista vazia, não erro" do
      notas, = ler(VAZIO)

      assert_empty notas
    end

    test "token inválido levanta erro de autenticação" do
      erro = assert_raises(T::V2Client::AuthError) { ler(ERRO_TOKEN) }

      assert_includes erro.message, "Token"
    end

    test "v3 avisa que ainda não está implementada" do
      erro = assert_raises(T::V3Client::NotImplemented) { T::V3Client.new.pesquisar_notas }

      assert_includes erro.message, "v2"
    end

    # ------------------------------------------------------------ sincronização

    def sincronizar(tenant)
      T::InvoiceSync.new(
        tenant: tenant,
        reader: T::Reader.new(client: ClienteEspiao.new(HttpFalso.new(PAGINA1, PAGINA2)))
      ).call(start_date: DE, end_date: ATE)
    end

    test "nota do pedido conhecido é gravada e amarra lançamento e recebível" do
      tenant = criar_tenant
      conta = criar_conta(tenant: tenant)
      pedido = criar_pedido(tenant: tenant, conta: conta, external_id: "PED-ML-001")
      lancamento = criar_lancamento(tenant: tenant, conta: conta, pedido: pedido, valor: 119.99)
      recebivel = criar_recebivel(tenant: tenant, conta: conta, pedido: pedido, bruto: 119.99, liquido: 100)

      resumo = sincronizar(tenant)

      assert_equal 3, resumo[:lidas]
      # Duas: a do pedido que já existia e a do PED-SEM-PEDIDO, cujo pedido
      # passa a ser criado a partir da própria nota (ver o teste abaixo).
      assert_equal 2, resumo[:criadas]
      assert_equal 0, resumo[:sem_pedido]
      assert_equal 1, resumo[:sem_referencia], "nota sem numero_ecommerce"

      nota = Invoice.find_by(tenant: tenant, number: "251372")

      assert_equal pedido.id, nota.order_id
      assert_equal 44, nota.access_key.to_s.size
      assert_equal "issued", nota.status
      assert_equal nota.id, lancamento.reload.invoice_id
      assert_equal nota.id, recebivel.reload.invoice_id
    end

    # A NF é a única fonte que tem o número do PEDIDO do marketplace: o
    # relatório de liberações do Mercado Livre não traz.
    #
    # Exigir que o pedido já existisse fazia o sync descartar tudo — com o
    # razão vindo só do extrato, nenhuma das 4027 notas do cliente encontraria
    # pedido, e a corrente pedido -> NF -> título nunca começava.
    test "pedido que não existe é criado a partir da própria nota" do
      tenant = criar_tenant
      conta = criar_conta(tenant: tenant)

      resumo = sincronizar(tenant)

      assert_equal 2, resumo[:pedidos_criados]

      pedido = Order.find_by(tenant: tenant, external_id: "PED-SEM-PEDIDO")

      assert_not_nil pedido
      assert_equal conta.id, pedido.platform_account_id
      assert_equal "tiny_invoice_sync", pedido.metadata["origem"]
      assert_equal pedido.id, Invoice.find_by(tenant: tenant, order_id: pedido.id)&.order_id
    end

    # Atribuir a nota ao marketplace errado estragaria a conciliação daquela
    # conta, e a nota do Tiny não diz de qual marketplace ela é.
    test "com mais de um marketplace na empresa, não chuta o pedido" do
      tenant = criar_tenant
      criar_conta(tenant: tenant, plataforma: "mercado_livre")
      criar_conta(tenant: tenant, plataforma: "shopee")

      resumo = sincronizar(tenant)

      assert_equal 0, resumo[:pedidos_criados]
      assert_operator resumo[:sem_plataforma].to_i, :>, 0
      assert_equal 0, Order.where(tenant: tenant).count
    end

    test "reprocessar atualiza em vez de duplicar" do
      tenant = criar_tenant
      conta = criar_conta(tenant: tenant)
      criar_pedido(tenant: tenant, conta: conta, external_id: "PED-ML-001")

      sincronizar(tenant)
      segundo = sincronizar(tenant)

      assert_equal 0, segundo[:criadas]
      # Duas notas com pedido: a do pedido criado à mão e a do pedido que o
      # próprio sync criou a partir da nota.
      assert_equal 2, segundo[:atualizadas]
      assert_equal 2, Invoice.where(tenant: tenant).count
      assert_equal 0, segundo[:pedidos_criados], "o pedido da primeira rodada já existe"
    end

    test "nota de devolução é lida como entrada e não rouba o vínculo da venda" do
      tenant = criar_tenant
      conta = criar_conta(tenant: tenant)
      pedido = criar_pedido(tenant: tenant, conta: conta, external_id: "PED-ML-001")
      lancamento = criar_lancamento(tenant: tenant, conta: conta, pedido: pedido, valor: 119.99)

      sincronizar(tenant)

      venda = Invoice.find_by!(tenant: tenant, number: "251372")

      http = HttpFalso.new(PAGINA_DEVOLUCAO)

      resumo = T::InvoiceSync
                 .new(tenant: tenant, reader: T::Reader.new(client: ClienteEspiao.new(http)))
                 .call(start_date: DE, end_date: ATE, devolucoes: true)

      assert_equal "E", http.chamadas.first[:tipoNota], "devolução é nota de entrada"
      assert_equal 1, resumo[:criadas]

      nota_de_devolucao = Invoice.find_by!(tenant: tenant, number: "700001")

      assert_equal "refund", nota_de_devolucao.operation_type
      assert_equal pedido.id, nota_de_devolucao.order_id, "amarrada ao mesmo pedido"
      assert_equal "sale", venda.reload.operation_type, "a NF de venda continua sendo venda"

      # O ponto: a devolução não pode sequestrar o lançamento da venda, senão a
      # baixa passa a apontar para a nota errada.
      assert_equal venda.id, lancamento.reload.invoice_id
    end

    test "número da nota do Tiny casa com o numero_documento do título no OMIE" do
      tenant = criar_tenant
      conta = criar_conta(tenant: tenant)
      criar_pedido(tenant: tenant, conta: conta, external_id: "PED-ML-001")
      sincronizar(tenant)

      nota = Invoice.find_by!(tenant: tenant, number: "251372")

      # O OMIE devolve o número zerado à esquerda; é a normalização que fecha
      # a corrente pedido -> NF -> título.
      assert_equal Omie::Readers::OpenTitles.normalizar_numero("0000251372"),
                   Omie::Readers::OpenTitles.normalizar_numero(nota.number)
    end
  end
end
