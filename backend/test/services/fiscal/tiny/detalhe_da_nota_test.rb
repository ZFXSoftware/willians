require "test_helper"

module Fiscal
  module Tiny
    class DetalheDaNotaTest < ActiveSupport::TestCase
      def setup
        @tenant = criar_tenant
        @conta = criar_conta(tenant: @tenant)
        @pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PED-1")
      end

      def nota(numero, id_tiny: nil)
        criar_nota(tenant: @tenant, pedido: @pedido, numero: numero, valor: 10)
          .tap { |n| n.update!(external_id: id_tiny || "TINY-#{numero}") }
      end

      # Devolve o intermediador pedido, e conta as chamadas: o custo é uma
      # consulta por nota, e reperguntar é cota do Tiny jogada fora.
      class TinyFalso
        attr_reader :chamadas

        def initialize(por_id = {})
          @por_id = por_id
          @chamadas = []
        end

        def obter_nota(id)
          @chamadas << id

          @por_id.key?(id) ? @por_id[id] : { "intermediador" => { "nome" => "Shopee", "cnpj" => "35" } }
        end
      end

      def sincronizar(client, limite: 10)
        DetalheDaNota.new(tenant: @tenant, client: client, limite: limite, pausa: 0).call
      end

      # O desconto da nota é o que explica a diferença entre a venda no
      # marketplace e o valor da NF: a venda é igual ao `valor_produtos`.
      # Descartar este campo custou seis rodadas de hipótese errada.
      test "guarda os valores fiscais que a nota declara" do
        registro = nota("1")

        detalhe = {
          "intermediador" => { "nome" => "Mercado Livre", "cnpj" => "10" },
          "regime_tributario" => "1",
          "valor_produtos" => "184.65",
          "valor_desconto" => "6.00",
          "valor_nota" => "178.65",
          "valor_icms_st" => "0.00",
          "itens" => [ { "item" => { "cfop" => "6108", "ncm" => "6404.19.00" } } ]
        }

        sincronizar(TinyFalso.new("TINY-1" => detalhe))

        fiscal = registro.reload.metadata["fiscal"]

        assert_equal "6.00", fiscal["valor_desconto"]
        assert_equal "184.65", fiscal["valor_produtos"]
        assert_equal "1", fiscal["regime_tributario"]
        assert_equal [ "6108" ], fiscal["cfops"]
        assert_equal [ "6404.19.00" ], fiscal["ncms"]
      end

      # Nome, CPF e endereço do comprador vêm na MESMA resposta. Não há por que
      # copiá-los para dentro da nossa nota para responder uma pergunta fiscal.
      test "não copia dado do comprador" do
        registro = nota("1")

        detalhe = {
          "intermediador" => { "nome" => "Mercado Livre", "cnpj" => "10" },
          "valor_desconto" => "6.00",
          "cliente" => { "nome" => "Alguém", "cpf_cnpj" => "073.209.915-35" }
        }

        sincronizar(TinyFalso.new("TINY-1" => detalhe))

        guardado = registro.reload.metadata.to_json

        assert_not_includes guardado, "073.209.915-35"
        assert_not_includes guardado, "Alguém"
      end

      # As notas já lidas têm intermediador e não têm `fiscal`. Sem reperguntar,
      # o dado fiscal valeria só para nota nova e a base histórica ficaria cega.
      test "nota já lida sem os valores fiscais volta para a fila" do
        registro = nota("1")

        registro.update!(metadata: { "intermediador" => { "nome" => "Shopee", "cnpj" => "35" } })

        client = TinyFalso.new

        sincronizar(client)

        assert_equal [ "TINY-1" ], client.chamadas
        assert registro.reload.metadata["fiscal"].present?
      end

    # "Nota Fiscal não localizada" não muda de resposta. Reperguntar a cada cinco
    # minutos é cota do Tiny jogada fora — o mesmo desperdício das notas
    # recusadas pelo OMIE, que já corrigimos uma vez nesta base.
    test "nota que o Tiny diz não conhecer sai da fila" do
      registro = nota("1")

      client = Class.new do
        attr_reader :chamadas

        def initialize = @chamadas = []

        def obter_nota(id)
          @chamadas << id

          raise Fiscal::Tiny::V2Client::ApiError,
                "Tiny recusou nota.fiscal.obter.php: Nota Fiscal não localizada"
        end
      end.new

      sincronizar(client)

      assert registro.reload.metadata.to_h["tiny_recusa"].present?

      sincronizar(client)

      assert_equal 1, client.chamadas.size, "reperguntou uma nota que o Tiny já recusou"
    end

    # "API Bloqueada" é excesso de acesso: a resposta muda sozinha em minutos.
    # Marcar como definitiva perderia a nota por um erro que ia passar.
    test "bloqueio temporário do Tiny não tira a nota da fila" do
      registro = nota("1")

      client = Class.new do
        attr_reader :chamadas

        def initialize = @chamadas = []

        def obter_nota(id)
          @chamadas << id

          raise Fiscal::Tiny::V2Client::ApiError,
                "Tiny recusou nota.fiscal.obter.php: API Bloqueada - Excedido o número de acessos"
        end
      end.new

      sincronizar(client)

      # `to_h` porque a coluna aceita nulo: nota criada por outro caminho chega
      # sem metadata nenhum, e é assim que o código de produção a trata.
      assert_nil registro.reload.metadata.to_h["tiny_recusa"]

      sincronizar(client)

      assert_equal 2, client.chamadas.size, "devia ter tentado de novo"
    end

    test "grava o intermediador na nota" do
        nota("1")

        resumo = sincronizar(TinyFalso.new)

        assert_equal 1, resumo[:lidas]
        assert_equal "Shopee", Invoice.find_by(tenant: @tenant, number: "1").metadata.dig("intermediador", "nome")
      end

      # Uma consulta por nota, com pausa: reperguntar o que já se sabe é a
      # diferença entre o backfill terminar em uma hora ou nunca.
      test "não repergunta o que já foi lido" do
        nota("1")

        client = TinyFalso.new

        sincronizar(client)
        sincronizar(client)

        assert_equal 1, client.chamadas.size
      end

      # O Tiny responder "não sei" é RESPOSTA, e fica gravada como tal. Sem
      # distinguir de "ainda não perguntei", essas notas voltariam para a fila
      # a cada volta do ciclo, para sempre — o mesmo defeito que as notas
      # recusadas no envio ao OMIE tinham.
      test "nota sem intermediador não volta para a fila" do
        nota("1")

        client = TinyFalso.new("TINY-1" => { "intermediador" => nil })

        primeiro = sincronizar(client)

        assert_equal 1, primeiro[:lidas]
        assert_nil Invoice.find_by(tenant: @tenant, number: "1").metadata.dig("intermediador", "nome")

        assert_equal 0, sincronizar(client)[:lidas]
        assert_equal 1, client.chamadas.size
      end

      # Milhares de notas a uma consulta por segundo não cabem numa volta do
      # ciclo. O que sobra precisa ser dito, para o ciclo seguinte continuar.
      test "lê em lote e diz quantas faltam" do
        3.times { |i| nota("N#{i}") }

        resumo = sincronizar(TinyFalso.new, limite: 2)

        assert_equal 2, resumo[:lidas]
        assert_equal 1, resumo[:pendentes]
      end

      test "nota que o Tiny não devolve conta como falha e não trava as outras" do
        nota("1")
        nota("2")

        client = TinyFalso.new("TINY-1" => nil)

        resumo = sincronizar(client)

        assert_equal 1, resumo[:falhas]
        assert_equal 1, resumo[:lidas]
      end
    end
  end
end
