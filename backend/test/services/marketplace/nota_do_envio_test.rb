require "test_helper"

module Marketplace
  module MercadoLivre
    # O elo que faltava, depois de quatro fontes tentadas: o marketplace exige
    # a nota para despachar e guarda a CHAVE. Casamento por identidade, não por
    # semelhança — chave de acesso é única.
    class NotaDoEnvioTest < ActiveSupport::TestCase
      CHAVE = "35260741273506000151550020000416991841804204".freeze

      def setup
        @tenant = criar_tenant
        @conta = criar_conta(tenant: @tenant, plataforma: "mercado_livre")
        @pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PED-1")
        @unidade = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido)
      end

      class MLFalso
        def initialize(chave: CHAVE, envio: "999") = (@chave = chave; @envio = envio)

        def bruto(_caminho) = { "shipping" => { "id" => @envio } }

        def invoice_data(_envio, site: "MLB")
          return if @chave.blank?

          { chave: @chave, serie: "2", numero: "041699", valor: "100.00", data: "2026-08-07" }
        end
      end

      def ligar(client = MLFalso.new, dry_run: false)
        NotaDoEnvio.new(
          tenant: @tenant, platform_account: @conta, client: client, pausa: 0, dry_run: dry_run
        ).call
      end

      def nota_com(chave)
        criar_nota(tenant: @tenant, pedido: @pedido, numero: "041699", valor: 100).tap do |nota|
          nota.update!(operation_type: :sale, access_key: chave)
        end
      end

      test "liga a venda à nota pela chave que o marketplace guarda" do
        nota = nota_com(CHAVE)

        resumo = ligar

        assert_equal 1, resumo[:ligadas]
        assert_equal nota.id, @unidade.reload.invoice_id
      end

      # A chave vem do marketplace sem formatação e a nossa pode ter vindo com
      # pontuação. Comparar cru faria a mesma nota parecer duas.
      test "a formatação da chave não decide o casamento" do
        nota_com(CHAVE.scan(/.{4}/).join(" "))

        assert_equal 1, ligar[:ligadas]
      end

      # 13 de 30 notas do cliente estão sem `access_key` — a importação do Tiny
      # não a trouxe. Casar só por chave as deixaria de fora para sempre, por
      # falta de um dado que o marketplace tem em mãos.
      test "nota sem chave é ligada pelo número, e a chave é preenchida" do
        nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "041699", valor: 100)

        nota.update!(operation_type: :sale, series: "2", access_key: nil)

        resumo = ligar

        assert_equal 1, resumo[:ligadas_pelo_numero]
        assert_equal nota.id, @unidade.reload.invoice_id
        assert_equal CHAVE, nota.reload.access_key
      end

      # Chave gravada é dado do documento: informação de terceiro não a
      # sobrescreve.
      test "não sobrescreve chave que já existe" do
        outra = "35260741273506000151550020000000000000000000"

        nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "041699", valor: 100)

        nota.update!(operation_type: :sale, series: "2", access_key: outra)

        ligar

        assert_equal outra, nota.reload.access_key
      end

      # Nota que existe no marketplace e não no nosso banco é RESPOSTA, não
      # fracasso: guardar o número e a série é o que permite ir buscá-la.
      test "nota que não temos fica registrada no pedido" do
        assert_equal 1, ligar[:nao_temos]

        assert_equal "041699", @pedido.reload.metadata.dig("nota_do_envio", "numero")
        assert_nil @unidade.reload.invoice_id
      end

      # Duas chamadas por venda, para sempre, seria o mesmo desperdício das
      # notas recusadas que ficavam na fila do OMIE.
      test "não pergunta duas vezes pelo mesmo pedido" do
        ligar

        assert_equal 0, ligar[:ligadas] + ligar[:nao_temos]
      end

      test "pedido sem nota no marketplace também é marcado" do
        resumo = ligar(MLFalso.new(chave: nil))

        assert_equal 1, resumo[:sem_nota_no_ml]
        assert_equal "sem nota no marketplace", @pedido.reload.metadata["nota_do_envio"]
      end

      test "sem envio não há o que perguntar" do
        assert_equal 1, ligar(MLFalso.new(envio: nil))[:sem_envio]
      end

      test "simulação não liga nem marca" do
        nota_com(CHAVE)

        assert_equal 1, ligar(dry_run: true)[:ligadas]
        assert_nil @unidade.reload.invoice_id
        assert_nil @pedido.reload.metadata["nota_do_envio"]
      end
    end
  end
end
