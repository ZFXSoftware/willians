require "test_helper"

module Fiscal
  module Tiny
    class IntermediadorSyncTest < ActiveSupport::TestCase
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
        IntermediadorSync.new(tenant: @tenant, client: client, limite: limite, pausa: 0).call
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
