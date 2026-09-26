require "test_helper"

module Conciliacao
  # O OMIE bloqueia requisição idêntica repetida e DIZ quanto esperar. A
  # conciliação ignorava esse número: desistia do índice de títulos e deixava
  # cada conta repetir a mesma chamada na hora, tomando o mesmo bloqueio — e a
  # execução inteira falhava por um limite que passa em um minuto.
  class EsperaDoOmieTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
    end

    # Cliente que recusa a primeira chamada com o bloqueio do OMIE e aceita a
    # segunda, que é exatamente o comportamento do limite: temporário.
    class BloqueiaUmaVez
      attr_reader :chamadas

      def initialize(segundos:)
        @segundos = segundos

        @chamadas = 0
      end

      # A interface real do cliente do OMIE é `request(endpoint, call, **params)`.
      # Meu primeiro falso implementou `listar_contas_receber`, que não existe —
      # e aí o teste falhava por não chamar nada, o que parece "não repetiu".
      def request(_endpoint, _call, **_params)
        @chamadas += 1

        if @chamadas == 1
          raise Omie::Client::RedundantConsumption.new(
            "Omie bloqueou ListarContasReceber por consumo redundante",
            retry_after: @segundos
          )
        end

        { "conta_receber_cadastro" => [], "total_de_paginas" => 1 }
      end
    end

    # Subclasse em vez de mock: `minitest/mock` quebra o parse de argumentos
    # nesta versão, e sobrescrever um método é mais honesto de ler.
    class SemDormir < ConciliacaoService
      def esperas = @esperas ||= []

      private

      def esperar(segundos)
        esperas << segundos
      end
    end

    def rodar(client)
      servico = SemDormir.new(
        tenant: @tenant,
        start_date: Date.current - 30,
        end_date: Date.current,
        omie_client: client,
        sincronizar: false
      )

      servico.processar

      servico.esperas
    end

    test "espera o tempo que o OMIE pediu e tenta de novo" do
      client = BloqueiaUmaVez.new(segundos: 54)

      esperas = rodar(client)

      assert_equal 2, client.chamadas, "não repetiu a chamada depois de esperar"
      assert_equal [ 55 ], esperas, "esperou o que o OMIE pediu, com um segundo de folga"
    end

    # Espera longa não é espera, é execução travada: cinco minutos parados num
    # ciclo que roda a cada cinco não pode acontecer.
    test "não espera além do limite" do
      client = BloqueiaUmaVez.new(segundos: 900)

      esperas = rodar(client)

      assert_empty esperas, "espera de 900s travaria o ciclo; não devia ter dormido"

      # DUAS chamadas e não uma, e isso é correto: a segunda é o fallback que já
      # existia — sem o índice, cada conta tenta por conta própria e reporta o
      # erro dela. Eu tinha escrito `assert_equal 1` e lido a falha como "tentou
      # de novo quando não devia", quando o segundo pedido vem de outro caminho.
      assert_equal 2, client.chamadas,
                   "a segunda chamada é o fallback por conta, não a espera"
    end
  end
end
