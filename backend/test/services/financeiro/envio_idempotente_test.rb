require "test_helper"

module Financeiro
  # O envio ao OMIE não se protegia de resposta perdida.
  #
  # `codigo_lancamento_integracao` é determinístico (`...-NF-<id>`), mas se o
  # IncluirContaReceber sucede e a resposta não volta, a nota continua marcada
  # como não enviada e a volta seguinte cria o SEGUNDO título. Aconteceu em
  # produção com a NF 854054: R$ 169,65 a mais no valor esperado, com os dois
  # títulos carregando o MESMO código de integração — o OMIE aceitou o repetido.
  #
  # Com 225 notas na fila, isso deixa de ser hipótese.
  class EnvioIdempotenteTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)

      @tenant.update!(metadata: {
        "omie_conta_corrente_id" => "777",
        "omie_cliente_fornecedor_id" => "999"
      })

      pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PED-850512")

      @nota = criar_nota(tenant: @tenant, pedido: pedido, numero: "850512", valor: 134.65)

      @nota.update!(operation_type: :sale, metadata: {
        "comprador_nome" => "Sirley Ribeiro Garcia",
        "comprador_documento" => "557.886.962-91"
      })
    end

    def codigo = Omie::Mappers::InvoiceMapper.codigo_de(@nota)

    # `titulos` é o que o OMIE já tem; `erro_no_titulo` simula a resposta que
    # significa "não sei se gravei".
    class OmieEspiao
      attr_reader :chamadas

      def initialize(titulos: [], erro_no_titulo: nil)
        @chamadas = []
        @titulos = titulos
        @erro_no_titulo = erro_no_titulo
      end

      def incluiu_titulo? = @chamadas.any? { |call, _| call == "IncluirContaReceber" }

      def request(_endpoint, call, params = {})
        @chamadas << [ call, params ]

        case call
        when "ListarContasReceber"
          { "conta_receber_cadastro" => @titulos, "total_de_paginas" => 1 }
        when "ListarClientes"
          { "clientes_cadastro" => [ { "codigo_cliente_omie" => 555 } ] }
        when "IncluirContaReceber"
          raise @erro_no_titulo if @erro_no_titulo

          { "codigo_lancamento_omie" => 4242 }
        else
          { "codigo_lancamento_omie" => 4242 }
        end
      end
    end

    def enviar(espiao)
      EnvioDeNotasAoOmie.new(
        tenant: @tenant, client: espiao, dry_run: false, pausa: 0
      ).call
    end

    # O conserto: perguntar ANTES de enviar. Cura o passado também — a nota cuja
    # resposta se perdeu sai da fila em vez de ser reenviada para sempre.
    test "nota que o OMIE já tem não é enviada de novo" do
      espiao = OmieEspiao.new(titulos: [
        { "numero_documento_fiscal" => "850512", "valor_documento" => 134.65,
          "codigo_lancamento_integracao" => codigo }
      ])

      resumo = enviar(espiao)

      assert_not espiao.incluiu_titulo?, "reenviou uma nota que já está no OMIE"
      assert_equal 1, resumo[:ja_no_omie]
      assert_equal 0, resumo[:enviadas]
      assert_equal codigo, @nota.reload.metadata["omie_codigo_lancamento"],
                   "precisa sair da fila, senão volta na execução seguinte"
    end

    # Título de OUTRA nota no OMIE não pode barrar esta: o índice é por código,
    # não por "existe algum título".
    test "título de outra nota não impede o envio desta" do
      espiao = OmieEspiao.new(titulos: [
        { "numero_documento_fiscal" => "999999", "valor_documento" => 10.0,
          "codigo_lancamento_integracao" => "OUTRO-NF-99999" }
      ])

      resumo = enviar(espiao)

      assert espiao.incluiu_titulo?, "não enviou uma nota que o OMIE não tem"
      assert_equal 1, resumo[:enviadas]
    end

    # "Esta requisição já foi processada ou está sendo processada" é o momento em
    # que a duplicata nasce. Nem falha nem sucesso: incerteza.
    test "resposta incerta do OMIE não conta como falha nem marca como enviada" do
      espiao = OmieEspiao.new(
        erro_no_titulo: Omie::Client::MaybeProcessed.new(
          "Omie pode já ter processado IncluirContaReceber: ERROR: Esta requisição já foi processada"
        )
      )

      resumo = enviar(espiao)

      assert_equal 1, resumo[:talvez_no_omie]
      assert_equal 0, resumo[:falhas],
                   "contar como falha travaria o automático por incerteza"
      assert_nil @nota.reload.metadata["omie_codigo_lancamento"],
                 "marcar como enviada sem saber esconderia uma nota que não entrou"
    end

    # Sem o índice o envio continua — pior, mas não parado.
    test "falha ao listar o que o OMIE tem não impede o envio" do
      espiao = Class.new(OmieEspiao) do
        def request(endpoint, call, params = {})
          raise Omie::Client::ApiError, "ERROR: indisponível" if call == "ListarContasReceber"

          super
        end
      end.new

      resumo = enviar(espiao)

      assert_equal 1, resumo[:enviadas]
    end
  end
end
