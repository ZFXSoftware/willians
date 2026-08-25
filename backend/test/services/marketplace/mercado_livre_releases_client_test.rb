require "test_helper"

module Marketplace
  # A geração do relatório é assíncrona: o POST responde 202 e o arquivo
  # aparece na lista minutos depois. O risco não é a rede — é o serviço ficar
  # travado esperando, ou pedir de novo um relatório que já existe.
  class MercadoLivreReleasesClientTest < ActiveSupport::TestCase
    ML = Marketplace::MercadoLivre

    DE = Date.new(2026, 8, 1)

    ATE = Date.new(2026, 8, 7)

    CSV = "DATE,SOURCE_ID,ORDER_ID,RECORD_TYPE,GROSS_AMOUNT\n" \
          "2026-08-02T10:00:00Z,PAY-1,200001,release,10.00\n".freeze

    # Dublê no nível do HTTP: exercita a montagem da requisição de verdade.
    class HttpFalso
      Resposta = Struct.new(:code, :body) do
        def is_a?(klass) = klass == Net::HTTPSuccess ? code.to_i.between?(200, 299) : super
      end

      attr_reader :chamadas

      # `listas` é a sequência de respostas do /list: permite simular o
      # relatório aparecendo só na terceira consulta.
      def initialize(listas:, csv: CSV)
        @listas = listas
        @csv = csv
        @chamadas = []
      end

      def call(requisicao)
        caminho = requisicao.uri.path
        metodo = requisicao.method

        @chamadas << [metodo, caminho, requisicao.body]

        return Resposta.new("202", "") if metodo == "POST"

        return Resposta.new("200", (@listas.shift || @listas.last || []).to_json) if caminho.end_with?("/list")

        Resposta.new("200", @csv)
      end
    end

    def cliente(http, timeout: 30)
      c = ML::ReleasesClient.new(access_token: "AT", timeout: timeout, sleeper: ->(_s) { nil })

      c.define_singleton_method(:executar) { |req| c.send(:verificar!, http.call(req), req) }

      c
    end

    def relatorio_pronto
      [{ "file_name" => "release-report-2026-08-08.csv",
         "begin_date" => "2026-08-01T00:00:00Z", "end_date" => "2026-08-07T23:59:59Z" }]
    end

    test "reaproveita relatório já gerado do mesmo período" do
      http = HttpFalso.new(listas: [relatorio_pronto])

      assert_equal CSV, cliente(http).csv_for(start_date: DE, end_date: ATE)

      assert_empty http.chamadas.select { |m, _, _| m == "POST" },
                   "não pode pedir de novo um relatório que já existe"
    end

    test "cria e espera quando o período ainda não foi gerado" do
      # Vazio, vazio, e só então o arquivo aparece.
      http = HttpFalso.new(listas: [[], [], [], relatorio_pronto])

      assert_equal CSV, cliente(http).csv_for(start_date: DE, end_date: ATE)

      post = http.chamadas.find { |m, _, _| m == "POST" }

      assert post, "deveria ter pedido a geração"
      assert_equal "/v1/account/release_report", post[1]

      corpo = JSON.parse(post[2])

      assert_equal "2026-08-01T00:00:00Z", corpo["begin_date"]
      # Fim do dia: senão o último dia do período fica de fora.
      assert_equal "2026-08-07T23:59:59Z", corpo["end_date"]
    end

    # A janela padrão da conciliação termina em Date.current, então o fim do
    # dia de hoje — que está no futuro — era o que ia no pedido todo dia.
    test "não pede relatório de um período que termina no futuro" do
      http = HttpFalso.new(listas: [ [] ])

      # O download não interessa aqui; o que importa é o que foi PEDIDO.
      assert_raises(ML::ReleasesClient::ReportPending) do
        cliente(http, timeout: 5).csv_for(start_date: Date.current - 7, end_date: Date.current)
      end

      corpo = JSON.parse(http.chamadas.find { |m, _, _| m == "POST" }[2])

      assert_operator Time.parse(corpo["end_date"]), :<=, Time.current
    end

    # Sem isto, "HTTP 400" é um beco sem saída: o fluxo faz três chamadas
    # diferentes, e a explicação do Mercado Pago vem no corpo.
    test "erro diz qual chamada falhou e o que a plataforma respondeu" do
      http = Object.new

      def http.call(_req)
        HttpFalso::Resposta.new("400", '{"message":"end_date must not be in the future"}')
      end

      erro = assert_raises(ML::ReleasesClient::Error) do
        cliente(http).csv_for(start_date: DE, end_date: ATE)
      end

      assert_includes erro.message, "GET /v1/account/release_report/list"
      assert_includes erro.message, "end_date must not be in the future"
    end

    # Lista em formato não previsto virava [] em silêncio — e como quem chama
    # espera o arquivo APARECER nessa lista, o resultado era espera eterna sem
    # uma linha no log. É o formato de "sempre dá relatório ainda sendo gerado".
    test "lista em formato inesperado é denunciada, não tratada como vazia" do
      http = Object.new

      def http.call(_req) = HttpFalso::Resposta.new("200", '{"paging":{},"data":[]}')

      anterior = Rails.logger

      saida = StringIO.new

      Rails.logger = ActiveSupport::Logger.new(saida)

      begin
        assert_raises(ML::ReleasesClient::ReportPending) do
          cliente(http, timeout: 5).csv_for(start_date: DE, end_date: ATE)
        end
      ensure
        Rails.logger = anterior
      end

      assert_includes saida.string, "formato não previsto"
      assert_includes saida.string, "paging"
    end

    test "não fica esperando para sempre" do
      http = HttpFalso.new(listas: [[]])

      erro = assert_raises(ML::ReleasesClient::ReportPending) do
        cliente(http, timeout: 10).csv_for(start_date: DE, end_date: ATE)
      end

      assert_includes erro.message, "ainda está sendo gerado"
    end

    test "relatório de outro período não é confundido com o nosso" do
      outro = [{ "file_name" => "x.csv", "begin_date" => "2026-07-01T00:00:00Z",
                 "end_date" => "2026-07-31T23:59:59Z" }]

      http = HttpFalso.new(listas: [outro])

      assert_raises(ML::ReleasesClient::ReportPending) do
        cliente(http, timeout: 10).csv_for(start_date: DE, end_date: ATE)
      end
    end

    test "baixa pelo nome do arquivo devolvido na lista" do
      http = HttpFalso.new(listas: [relatorio_pronto])

      cliente(http).csv_for(start_date: DE, end_date: ATE)

      download = http.chamadas.last

      assert_equal "/v1/account/release_report/release-report-2026-08-08.csv", download[1]
    end

    test "token recusado é erro de autenticação, não de rede" do
      http = Object.new

      def http.call(_req) = HttpFalso::Resposta.new("401", "")

      assert_raises(ML::ReleasesClient::AuthError) do
        cliente(http).csv_for(start_date: DE, end_date: ATE)
      end
    end

    # Este teste dizia o contrário: que a pendência virava lista vazia.
    #
    # Virava mesmo — e chegava na tela como "importação concluída — 0
    # lançamento(s)", indistinguível de uma conta que não vendeu nada. Quem
    # decide o que fazer com a espera é o SincronizacaoService, e para decidir
    # ele precisa saber que ela aconteceu.
    test "geração pendente sobe em vez de virar lista vazia" do
      pendente = ML::ReleasesClient::ReportPending.new("ainda gerando")

      provider = Providers::MercadoLivreProvider.allocate

      provider.define_singleton_method(:releases_client) do
        Object.new.tap { |o| o.define_singleton_method(:csv_for) { |**| raise pendente } }
      end

      provider.define_singleton_method(:ingerir_faturamento?) { false }

      assert_raises(ML::ReleasesClient::ReportPending) do
        provider.financial_events(start_date: DE, end_date: ATE)
      end
    end
  end
end
