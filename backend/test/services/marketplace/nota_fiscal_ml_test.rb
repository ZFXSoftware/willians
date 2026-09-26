require "test_helper"

module Marketplace
  # Parte das notas do cliente não sai pelo Tiny: o Mercado Livre emite pelo
  # vendedor, com o CNPJ dele, na MESMA série. O PDF do portal da SEFAZ mostrou
  # `verProc: mercadolivre.invoice` numa das 232 que faltavam.
  class NotaFiscalMlTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
      @pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PED-1")

      @pedido.update!(metadata: { "nota_do_envio" => { "numero" => "42289", "serie" => "2" } })

      @unidade = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido,
                                 bruto: 184.65, liquido: 184.65, external_id: "MLREL-1-SALE")
    end

    CHAVE = "35260841273506000151550020000422891275919240".freeze

    def resposta(cancelada: false, chave: CHAVE)
      {
        "id" => 6_688_681_706,
        "status" => cancelada ? "canceled" : "authorized",
        "invoice_number" => 42_289,
        "invoice_series" => 2,
        "issued_date" => "2026-08-06T21:23:10.864Z",
        "amount" => 180.65,
        "items_amount" => 184.65,
        "issuer" => {
          "identifications" => { "crt" => "simples", "cnpj" => "41273506000151" },
          "name" => "NÃO DEVE SER COPIADO"
        },
        "recipient" => { "name" => "Comprador", "identifications" => { "cpf" => "107.312.566-11" } },
        "items" => [ {
          "quantity" => 1,
          "total_amount" => 184.65,
          "discount_amount" => { "unconditional" => 4 },
          "fiscal_data" => { "attributes" => { "cfop" => "6106", "ncm" => "64029990", "csosn" => "102" } }
        } ],
        "attributes" => {
          "invoice_key" => chave,
          "invoice_source" => "internal",
          "protocol" => "135263187407226",
          "authorization_date" => "2026-08-06T21:23:14.000Z",
          "cancellation_date" => cancelada ? "2026-08-06T21:25:16.000Z" : nil,
          "xml_location" => "/users/1/invoices/documents/abc",
          "reference_invoices" => [ { "invoice_key" => "3526" + "0" * 40 } ]
        }
      }
    end

    class MlFalso
      def initialize(corpo, status: 200)
        @corpo = corpo
        @status = status
      end

      def resposta_crua(_caminho) = [ @status, @corpo.to_json, "application/json" ]
    end

    def importar(client, dry_run: false)
      MercadoLivre::NotaFiscal.new(
        tenant: @tenant, platform_account: @conta, client: client, pausa: 0, dry_run: dry_run
      ).call
    end

    test "cria a nota que o Mercado Livre emitiu e liga à venda" do
      resumo = importar(MlFalso.new(resposta))

      assert_equal 1, resumo[:criada]

      nota = Invoice.find_by(tenant_id: @tenant.id)

      assert_equal "42289", nota.number
      assert_equal "2", nota.series
      assert_equal CHAVE, nota.access_key
      # `amount`, e não `items_amount`: é o total da nota, já com o desconto
      # abatido — o mesmo que vira título no OMIE.
      assert_equal BigDecimal("180.65"), nota.total_amount.to_d
      assert_equal "issued", nota.status
      assert_equal nota.id, @unidade.reload.invoice_id
    end

    test "guarda o fiscal que o Tiny não dá" do
      importar(MlFalso.new(resposta))

      fiscal = Invoice.find_by(tenant_id: @tenant.id).metadata["fiscal"]

      assert_equal "simples", fiscal["regime_tributario"]
      assert_equal "4.0", fiscal["valor_desconto"]
      assert_equal [ "6106" ], fiscal["cfops"]
      assert_equal [ "102" ], fiscal["csosns"]
      assert_equal "184.65", fiscal["valor_produtos"]
    end

    # O OMIE exige o cliente para criar o título, e o CPF é elemento da própria
    # NF-e. Recusar copiar não protegia ninguém — deixava o dado ausente só para
    # as notas do Mercado Livre e quebrava o envio de 15 delas.
    test "guarda nome e documento do comprador, que o título exige" do
      importar(MlFalso.new(resposta))

      metadata = Invoice.find_by(tenant_id: @tenant.id).metadata

      assert_equal "Comprador", metadata["comprador_nome"]
      assert_equal "107.312.566-11", metadata["comprador_documento"]
    end

    # Endereço, telefone e o cadastro do EMITENTE a operação não pede.
    test "não copia endereço nem dado do emitente" do
      importar(MlFalso.new(resposta))

      guardado = Invoice.find_by(tenant_id: @tenant.id).metadata.to_json

      assert_not_includes guardado, "NÃO DEVE SER COPIADO"
      assert_not_includes guardado, "street_name"
      assert_not_includes guardado, "zip_code"
    end

    # Criar é certo, para o histórico existir. Ligar faria a conciliação esperar
    # um título que nunca vem — é a mesma regra do `soltar_canceladas!`.
    test "nota cancelada é criada mas não ligada à venda" do
      resumo = importar(MlFalso.new(resposta(cancelada: true)))

      assert_equal 1, resumo[:cancelada]
      assert_equal "cancelled", Invoice.find_by(tenant_id: @tenant.id).status
      assert_nil @unidade.reload.invoice_id
    end

    # Venda cuja nota JÁ está no nosso banco não gasta chamada de API.
    #
    # Numa leva de 40 em produção, 27 eram assim: o marketplace era consultado
    # para descobrir o que um SELECT responde. Ligar essas é trabalho do
    # `ReligarPeloEnvio`, que roda no ciclo e não fala com ninguém.
    test "nota que já temos não entra na fila nem vira duplicata" do
      nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "42289", valor: 180.65)

      # A SÉRIE junto, porque `criar_nota` fixa "1" e o envio desta venda é da
      # série 2. Sem isso o teste passava por comparar só o número — a mesma
      # frouxidão que estava na consulta.
      nota.update!(access_key: CHAVE, series: "2")

      client = MlFalso.new(resposta)

      servico = MercadoLivre::NotaFiscal.new(
        tenant: @tenant, platform_account: @conta, client: client, pausa: 0, dry_run: false
      )

      assert_equal 0, servico.quantas_faltam, "a venda continuou na fila com a nota já no banco"

      servico.call

      assert_equal 1, Invoice.where(tenant_id: @tenant.id).count
    end

    # E a chave continua sendo a identidade quando a venda CHEGA a ser
    # processada: número diferente, mesma chave, não duplica.
    test "mesma chave com número diferente não vira duplicata" do
      nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "99999", valor: 180.65)

      nota.update!(access_key: CHAVE)

      resumo = importar(MlFalso.new(resposta))

      assert_equal 1, resumo[:ja_tinhamos]
      assert_equal 1, Invoice.where(tenant_id: @tenant.id).count
      assert_equal nota.id, @unidade.reload.invoice_id
    end

    # 20 notas duplicadas em produção por causa disto, e o caminho importa: a
    # marca `nota_do_envio` guarda o que PERGUNTAMOS, e a resposta diz qual
    # documento de fato existe. Quando os dois números divergem — venda de pacote,
    # nota reemitida — a fila deixa passar pela marca e a criação usa a resposta.
    #
    # A nota do Tiny entra com `access_key` VAZIA, e a busca da criação era só
    # pela chave. Encontrando 42289/2 do Tiny sem chave, o importador criava
    # 42289/2 do Mercado Livre ao lado, e cada uma virava título no OMIE.
    def com_marca_divergente
      @pedido.update!(metadata: { "nota_do_envio" => { "numero" => "99999", "serie" => "2" } })
    end

    test "nota do Tiny sem chave, mesmo número e série, não vira duplicata" do
      com_marca_divergente

      nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "42289", valor: 180.65)

      nota.update!(series: "2", access_key: nil)

      resumo = importar(MlFalso.new(resposta))

      assert_equal 1, resumo[:ja_tinhamos], "não reconheceu a nota que já estava lá"
      assert_equal 1, Invoice.where(tenant_id: @tenant.id).count, "criou duplicata"
      assert_equal nota.id, @unidade.reload.invoice_id
    end

    # E a chave vem de graça na resposta: preenchê-la faz a próxima importação
    # reconhecer a nota pelo primeiro critério, sem depender do número.
    test "a chave que faltava é preenchida na nota que já tínhamos" do
      com_marca_divergente

      nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "42289", valor: 180.65)

      nota.update!(series: "2", access_key: nil)

      resumo = importar(MlFalso.new(resposta))

      assert_equal 1, resumo[:chaves_preenchidas]
      assert_equal CHAVE, nota.reload.access_key
    end

    # Nota CANCELADA que já tínhamos não pode ser ligada à venda: brigaria com
    # `soltar_canceladas!`, uma ligando e a outra soltando a cada ciclo.
    test "nota cancelada que já tínhamos não é ligada à venda" do
      com_marca_divergente

      nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "42289", valor: 180.65)

      nota.update!(series: "2", access_key: nil, status: :cancelled)

      importar(MlFalso.new(resposta(cancelada: true)))

      assert_nil @unidade.reload.invoice_id
    end

    # Mesmo número em série DIFERENTE é outro documento.
    #
    # Dez vendas ficaram sem nota para sempre por causa disto: o cliente emite
    # nas séries 2 e 5, o Mercado Livre grava na 2 intercalando com o Tiny, e a
    # consulta comparava só o número. Bastava existir a nº N da série 5 para a
    # nº N da série 2 ser tratada como "já temos" e nunca ser buscada.
    test "mesmo número em série diferente continua na fila" do
      nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "42289", valor: 180.65)

      nota.update!(series: "5")

      servico = MercadoLivre::NotaFiscal.new(
        tenant: @tenant, platform_account: @conta, client: MlFalso.new(resposta), pausa: 0, dry_run: false
      )

      assert_equal 1, servico.quantas_faltam,
                   "a nº 42289 da série 5 escondeu a nº 42289 da série 2"

      servico.call

      assert_equal 2, Invoice.where(tenant_id: @tenant.id).count,
                   "a nota da série 2 não foi criada"

      assert_equal "2", @unidade.reload.invoice.series
    end

    # E a chave manda mesmo quando a série bate: ela é a identidade.
    test "chave igual barra a fila mesmo sem a série no envio" do
      @pedido.update!(metadata: { "nota_do_envio" => { "numero" => "42289", "chave" => CHAVE } })

      criar_nota(tenant: @tenant, pedido: @pedido, numero: "99999", valor: 180.65)
        .update!(access_key: CHAVE, series: "7")

      servico = MercadoLivre::NotaFiscal.new(
        tenant: @tenant, platform_account: @conta, client: MlFalso.new(resposta), pausa: 0, dry_run: false
      )

      assert_equal 0, servico.quantas_faltam, "a chave igual devia ter barrado a busca"
    end

    # Preencher o comprador não basta: o envio pula toda nota com recusa
    # gravada. `liberar_recusa_se_mudou!` só era chamada pela importação do
    # Tiny, e as notas do Mercado Livre não passam por lá — 15 ficaram com
    # recusa velha DEPOIS de o comprador ter sido preenchido.
    test "completar o comprador libera a recusa velha do OMIE" do
      nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "42289", valor: 180.65)

      nota.update!(metadata: {
        "origem" => "mercado_livre",
        "omie_recusa" => { "motivo" => "sem_comprador", "assinatura" => "180.65|" }
      })

      servico = MercadoLivre::NotaFiscal.new(
        tenant: @tenant, platform_account: @conta, client: MlFalso.new(resposta),
        pausa: 0, dry_run: false
      )

      resumo = servico.completar_compradores

      assert_equal 1, resumo[:completadas]
      assert_equal 1, resumo[:liberadas]
      assert_nil nota.reload.metadata["omie_recusa"]
      assert_equal "107.312.566-11", nota.metadata["comprador_documento"]
    end

    test "simulação não grava" do
      resumo = importar(MlFalso.new(resposta), dry_run: true)

      assert_equal 1, resumo[:criada]
      assert_equal 0, Invoice.where(tenant_id: @tenant.id).count
    end
  end
end
