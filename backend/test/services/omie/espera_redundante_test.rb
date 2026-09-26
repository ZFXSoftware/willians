require "test_helper"

module Omie
  # O OMIE bloqueia a MESMA requisição repetida por cerca de um minuto e informa
  # quanto esperar. Esperar é o certo quando a repetição é legítima: dois
  # leitores precisando do mesmo relatório na mesma janela não é defeito.
  #
  # Eu havia posto essa espera dentro do `ConciliacaoService`, que é UM chamador.
  # Minutos depois a mesma parede derrubou a auditoria de títulos, pedindo
  # exatamente a requisição que a conciliação tinha acabado de fazer. O
  # tratamento pertence ao cliente, onde todos passam.
  class EsperaRedundanteTest < ActiveSupport::TestCase
    # Substitui só o transporte: o resto do cliente roda de verdade, inclusive o
    # `parse!` que transforma a mensagem do OMIE na exceção com `retry_after`.
    class ClienteFalso < Client
      attr_reader :chamadas, :esperas

      # O transporte está dublado, então nenhuma chamada real sai — mas a trava
      # do `RedeExterna` não tem como saber disso, e ela roda antes do `post`. O
      # próprio cliente prevê esta costura, e usá-la é melhor que ligar
      # PERMITIR_REDE_EM_TESTE: a trava continua valendo para o código de verdade.
      def self.network_allowed_in_test? = true

      def initialize(respostas)
        @respostas = respostas
        @chamadas = 0
        @esperas = []

        super(app_key: "k", app_secret: "s")
      end

      private

      def sleep(segundos) = @esperas << segundos

      def post(_uri, _body)
        @chamadas += 1

        corpo = @respostas[[ @chamadas - 1, @respostas.size - 1 ].min]

        resposta = Net::HTTPOK.new("1.1", "200", "OK")

        resposta.instance_variable_set(:@body, corpo)

        resposta.instance_variable_set(:@read, true)

        resposta
      end
    end

    BLOQUEIO = {
      "faultstring" => "ERROR: Consumo redundante detectado. Aguarde 54 segundos para tentar novamente (REDUNDANT).",
      "faultcode" => "SOAP-ENV:Client"
    }.to_json

    OK = { "conta_receber_cadastro" => [], "total_de_paginas" => 1 }.to_json

    test "espera o tempo informado e repete a chamada" do
      cliente = ClienteFalso.new([ BLOQUEIO, OK ])

      resposta = cliente.request("/financas/contareceber/", "ListarContasReceber", pagina: 1)

      assert_equal 2, cliente.chamadas, "não repetiu depois de esperar"
      assert_equal [ 55 ], cliente.esperas, "esperou o que o OMIE pediu, com um segundo de folga"
      assert_equal 1, resposta["total_de_paginas"]
    end

    # Bloqueio que não passa tem de subir: insistir para sempre seria pior que
    # falhar, e quem chama precisa poder decidir.
    test "desiste depois das tentativas e propaga o erro" do
      cliente = ClienteFalso.new([ BLOQUEIO ])

      assert_raises(Client::RedundantConsumption) do
        cliente.request("/financas/contareceber/", "ListarContasReceber", pagina: 1)
      end

      assert_operator cliente.chamadas, :<=, Client::MAX_ATTEMPTS
    end

    # Sem o número de segundos não há o que esperar, e tentar às cegas rende o
    # bloqueio outra vez.
    test "sem o tempo informado não espera" do
      sem_tempo = {
        "faultstring" => "ERROR: Consumo redundante detectado.",
        "faultcode" => "SOAP-ENV:Client"
      }.to_json

      cliente = ClienteFalso.new([ sem_tempo ])

      assert_raises(Client::RedundantConsumption) do
        cliente.request("/financas/contareceber/", "ListarContasReceber", pagina: 1)
      end

      assert_equal 1, cliente.chamadas
      assert_empty cliente.esperas
    end
  end
end
