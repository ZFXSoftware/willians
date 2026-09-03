require "test_helper"

module Omie
  module Readers
    # Zero à esquerda não pode decidir se um título é encontrado.
    #
    # As notas do cliente saem em duas séries — "042054" e "852276" — e o OMIE
    # guarda o número como o sistema que criou o título mandou. Comparando as
    # strings cruas, "042054" e "42054" são títulos diferentes, e o repasse sai
    # como "sem título correspondente" por causa de um zero.
    class ReceivableTotalsNormalizacaoTest < ActiveSupport::TestCase
      test "zero à esquerda não muda o título" do
        assert_equal ReceivableTotals.normalizar("042054"), ReceivableTotals.normalizar("42054")
        assert_equal "42054", ReceivableTotals.normalizar("00042054")
      end

      test "espaço em volta não muda o título" do
        assert_equal "852276", ReceivableTotals.normalizar("  852276 ")
      end

      # Número só de zeros existe: virar string vazia o tiraria do índice em
      # silêncio, e um título desaparecido é pior que um título estranho.
      test "número só de zeros não vira nada" do
        assert_equal "000", ReceivableTotals.normalizar("000")
      end

      test "vazio continua vazio" do
        assert_nil ReceivableTotals.normalizar(nil)
        assert_nil ReceivableTotals.normalizar("   ")
      end

      # A prova de que os dois lados agora se encontram.
      test "o índice do OMIE é montado pela chave normalizada" do
        client = Object.new

        def client.request(_endpoint, _call, _params = {})
          {
            "conta_receber_cadastro" => [
              { "numero_documento" => "042054", "valor_documento" => "123.70" }
            ],
            "total_de_paginas" => 1
          }
        end

        totais = ReceivableTotals.new(client: client).call(
          start_date: Date.current - 30, end_date: Date.current
        )

        assert_equal BigDecimal("123.70"), totais["42054"]
      end
    end
  end
end
