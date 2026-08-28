require "test_helper"

module Financeiro
  # O OMIE do cliente nasceu vazio e o faturamento dele vive no Tiny. Sem levar
  # as notas para lá, a conciliação compara o repasse do marketplace com o nada
  # — que é o "sem título correspondente" em todas as linhas da tela.
  #
  # O título vai contra o COMPRADOR, e não contra o marketplace, porque é assim
  # que o cliente lança hoje: a nota é emitida para o comprador e o título
  # espelha a nota.
  class EnvioDeNotasAoOmieTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)

      @tenant.update!(metadata: {
        "omie_conta_corrente_id" => "777",
        "omie_cliente_fornecedor_id" => "999"
      })
    end

    def criar_nota_do_tiny(numero: "850512", valor: 134.65, comprador: "Sirley Ribeiro Garcia",
                           documento: "557.886.962-91")
      # Um pedido por nota: duas notas do MESMO pedido esbarrariam no índice
      # único de pedidos, que não é o que este teste mede.
      pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "200001710087#{numero}")

      nota = criar_nota(tenant: @tenant, pedido: pedido, numero: numero, valor: valor)

      # `operation_type` é o que o InvoiceSync grava para distinguir a nota de
      # VENDA da de devolução — só a de venda vira título a receber.
      nota.update!(operation_type: :sale, metadata: {
        "comprador_nome" => comprador,
        "comprador_documento" => documento,
        "numero_ecommerce" => pedido.external_id
      })

      nota
    end

    # Grava as chamadas em vez de fazê-las: o que importa é o payload.
    #
    # `cliente_existente` simula a base real do cliente, onde os compradores já
    # estão cadastrados — foi por não considerar isso que nenhum título nascia.
    class OmieEspiao
      attr_reader :chamadas

      def initialize(cliente_existente: nil)
        @chamadas = []
        @cliente_existente = cliente_existente
      end

      def request(endpoint, call, params = {})
        @chamadas << [ call, params ]

        case call
        when "ListarClientes"
          return { "clientes_cadastro" => [ { "codigo_cliente_omie" => @cliente_existente } ] } if @cliente_existente

          raise Omie::Client::ApiError, "ERROR: Não existem registros para a consulta"
        when "IncluirCliente"
          { "codigo_cliente_omie" => 777 }
        else
          { "codigo_lancamento_omie" => 4242 }
        end
      end
    end

    def enviar(**args)
      espiao = OmieEspiao.new

      resumo = EnvioDeNotasAoOmie.new(
        tenant: @tenant, client: espiao, dry_run: false, pausa: 0, **args
      ).call

      [ resumo, espiao ]
    end

    # ------------------------------------------------------------- o payload

    test "o título vai contra o comprador da nota, não contra o marketplace" do
      criar_nota_do_tiny

      _, espiao = enviar

      cliente = espiao.chamadas.find { |call, _| call == "IncluirCliente" }&.last

      assert_not_nil cliente
      assert_equal "Sirley Ribeiro Garcia", cliente[:razao_social]
      assert_equal "55788696291", cliente[:cnpj_cpf], "sem pontuação, como o OMIE espera"
      assert_equal "S", cliente[:pessoa_fisica]
    end

    # A base do cliente JÁ TEM os compradores, com código de integração vazio.
    # Criar às cegas fazia o OMIE recusar pelo CPF repetido — "Cliente já
    # cadastrado ... com o Id [X] e código de integração []" — e nenhum título
    # nascia.
    #
    # A busca é LISTAGEM COM FILTRO e não consulta: `ConsultarCliente` só
    # aceita a chave do cadastro, e responde "Tag [CNPJ_CPF] não faz parte da
    # estrutura" — justamente a chave que não temos.
    test "comprador que já existe no OMIE é reaproveitado, não recriado" do
      criar_nota_do_tiny

      espiao = OmieEspiao.new(cliente_existente: 11_093_488_363)

      EnvioDeNotasAoOmie.new(
        tenant: @tenant, client: espiao, dry_run: false, pausa: 0
      ).call

      assert_nil espiao.chamadas.find { |call, _| call == "IncluirCliente" },
                 "não pode tentar criar quem já está lá"

      titulo = espiao.chamadas.find { |call, _| call == "IncluirContaReceber" }&.last

      assert_equal 11_093_488_363, titulo[:codigo_cliente_fornecedor]
    end

    # Dentro de um lote o mesmo comprador aparece em várias notas, e o OMIE
    # bloqueia repetição da mesma chamada em sequência.
    test "o mesmo comprador é resolvido uma vez só por execução" do
      criar_nota_do_tiny(numero: "1")
      criar_nota_do_tiny(numero: "2")

      _, espiao = enviar

      assert_equal 1, espiao.chamadas.count { |call, _| call == "IncluirCliente" },
                   "o segundo título usa o cadastro já resolvido"
      assert_equal 2, espiao.chamadas.count { |call, _| call == "IncluirContaReceber" }

      # Duas buscas para o MESMO comprador na primeira nota: sem pontuação e
      # com. O OMIE guarda formatado e não dá para saber se o filtro normaliza;
      # a segunda tentativa só acontece quando a primeira não achou, que é o
      # caminho em que o cadastro seria criado de qualquer forma.
      assert_equal 2, espiao.chamadas.count { |call, _| call == "ListarClientes" }
    end

    # É por este campo que o título encontra o repasse do marketplace: o
    # ReceivableTotals indexa o OMIE por numero_documento_fiscal/numero_documento.
    test "o número da NF vai no documento, que é a chave da conciliação" do
      criar_nota_do_tiny(numero: "850512")

      _, espiao = enviar

      titulo = espiao.chamadas.find { |call, _| call == "IncluirContaReceber" }&.last

      assert_equal "850512", titulo[:numero_documento]
      assert_equal 134.65, titulo[:valor_documento]
      assert_equal "777", titulo[:id_conta_corrente].to_s
    end

    # Decidido com o cliente: vence na data da nota.
    test "vencimento é a data de emissão da nota" do
      nota = criar_nota_do_tiny
      nota.update!(issued_at: Date.new(2026, 7, 1))

      _, espiao = enviar

      titulo = espiao.chamadas.find { |call, _| call == "IncluirContaReceber" }&.last

      assert_equal "01/07/2026", titulo[:data_vencimento]
      assert_equal "01/07/2026", titulo[:data_emissao]
    end

    # ----------------------------------------------------------- as recusas

    # Cadastro sem identificação na contabilidade de alguém é pior do que nota
    # não enviada — e o mesmo comprador viraria dois cadastros.
    test "nota sem CPF/CNPJ do comprador é recusada, não enviada torta" do
      criar_nota_do_tiny(documento: "")

      resumo, espiao = enviar

      assert_equal 1, resumo[:sem_comprador]
      assert_equal 0, resumo[:enviadas]
      assert_empty espiao.chamadas
    end

    # A lista de erros vinha SEMPRE vazia: o resumo é um Hash com padrão zero,
    # e `resumo[:erros] ||= []` encontrava 0, achava que estava preenchido e
    # não atribuía nada. A tela dizia "1 nota recusada pelo OMIE" e nenhuma
    # palavra sobre o motivo.
    test "a recusa do OMIE chega junto com o motivo" do
      criar_nota_do_tiny(numero: "850512")

      recusa = Object.new

      def recusa.request(_endpoint, call, _params = {})
        raise Omie::Client::ApiError, "ERROR: Cliente já cadastrado" if call == "ListarClientes"

        {}
      end

      resumo = EnvioDeNotasAoOmie.new(
        tenant: @tenant, client: recusa, dry_run: false, pausa: 0
      ).call

      assert_equal 1, resumo[:falhas]
      assert_equal 1, resumo[:erros].size, "contar a falha sem dizer o motivo não ajuda ninguém"
      assert_includes resumo[:erros].first, "850512"
      assert_includes resumo[:erros].first, "Cliente já cadastrado"
    end

    test "uma nota falha sem derrubar as outras" do
      criar_nota_do_tiny(numero: "1", documento: "")
      criar_nota_do_tiny(numero: "2")

      resumo, _ = enviar

      assert_equal 1, resumo[:sem_comprador]
      assert_equal 1, resumo[:enviadas]
    end

    # ------------------------------------------------------- idempotência

    test "nota já enviada não vai de novo" do
      criar_nota_do_tiny

      enviar

      resumo, espiao = enviar

      assert_equal 0, resumo[:previstas], "reenviar criaria um título duplicado no ERP"
      assert_empty espiao.chamadas
    end

    test "o código do OMIE fica guardado na nota" do
      nota = criar_nota_do_tiny

      enviar

      assert_equal 4242, nota.reload.metadata["omie_codigo_lancamento"]
    end

    # -------------------------------------------------------------- travas

    test "simulação não chama o OMIE, mas diz o que faria" do
      criar_nota_do_tiny

      espiao = OmieEspiao.new

      resumo = EnvioDeNotasAoOmie.new(
        tenant: @tenant, client: espiao, dry_run: true, pausa: 0
      ).call

      assert_equal 1, resumo[:previstas]
      assert_equal 0, resumo[:enviadas]
      assert_empty espiao.chamadas
      assert_equal 1, resumo[:amostra].size
    end

    # Cada nota são duas chamadas ao OMIE com pausa entre elas; milhares dão
    # horas. Sem teto, a requisição do navegador caía no meio e deixava o envio
    # pela metade — sem ninguém saber quantas foram.
    test "sem limite pedido, a execução é limitada a um lote" do
      (EnvioDeNotasAoOmie::LOTE_PADRAO + 5).times { |i| criar_nota_do_tiny(numero: "N#{i}") }

      resumo, _ = enviar

      assert_equal EnvioDeNotasAoOmie::LOTE_PADRAO, resumo[:previstas]
      assert_equal 5, resumo[:pendentes], "o que sobra precisa ser dito, para continuar depois"
    end

    test "limite permite provar com uma nota antes do lote" do
      criar_nota_do_tiny(numero: "1")
      criar_nota_do_tiny(numero: "2")

      resumo, _ = enviar(limite: 1)

      assert_equal 1, resumo[:previstas]
    end

    test "sem conta corrente configurada, recusa antes de começar" do
      @tenant.update!(metadata: {})

      criar_nota_do_tiny

      assert_raises(EnvioDeNotasAoOmie::ConfiguracaoAusente) { enviar }
    end
  end
end
