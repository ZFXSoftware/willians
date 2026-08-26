require "net/http"
require "json"

module Omie
  class Client
    BASE_URL = "https://app.omie.com.br/api/v1"

    OPEN_TIMEOUT = 5

    READ_TIMEOUT = 30

    MAX_ATTEMPTS = 3

    RETRIABLE = [
      Net::OpenTimeout,
      Net::ReadTimeout,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      Errno::EHOSTUNREACH,
      SocketError
    ].freeze

    # Qualquer chamada que não seja de leitura grava no ERP do cliente. O padrão
    # é bloquear: durante os testes com credencial real, uma escrita acidental
    # cria títulos e baixas de verdade na contabilidade dele.
    READ_PREFIXES = %w[Listar Consultar Pesquisar Obter].freeze

    # O Omie serializa chamadas por método e recusa uma segunda enquanto a
    # primeira roda: "Já existe uma requisição desse método sendo executada".
    # É temporário e deve ser repetido — ao contrário dos demais erros de
    # negócio, que são definitivos.
    CONCURRENT_REQUEST = /j[áa] existe uma requisi[çc][ãa]o desse m[ée]todo/i

    CONCURRENCY_BACKOFF = 3

    # Proteção diferente e mais severa: repetir a MESMA requisição em sequência
    # rende bloqueio de cerca de um minuto. Não é retentável de imediato — o
    # certo é não repetir a chamada.
    REDUNDANT_CONSUMPTION = /consumo redundante/i

    class Error < StandardError; end

    class TransportError < Error; end

    class ConcurrentRequest < Error; end

    class RedundantConsumption < Error
      attr_reader :retry_after

      def initialize(message, retry_after: nil)
        @retry_after = retry_after

        super(message)
      end
    end

    class WriteBlocked < Error; end

    # Rede real a partir da suíte de testes. Nunca deveria acontecer: as
    # credenciais do .env são as de PRODUÇÃO do cliente, e o processo de teste
    # herda o ambiente.
    class NetworkBlocked < Error; end

    class ApiError < Error
      attr_reader :fault_code

      def initialize(message, fault_code: nil)
        @fault_code = fault_code

        super(message)
      end
    end

    PROVEDOR = "omie".freeze

    def self.configured?(tenant: Current.tenant)
      Integracoes::Config.configurado?(PROVEDOR, tenant: tenant)
    end

    # Allowlist estrita de propósito. O cast booleano do Rails trata "no", "nao"
    # e "desligado" como VERDADEIRO — um valor desses no .env liberaria escrita
    # no ERP do cliente justamente quem tentou desligá-la.
    WRITE_ENABLED_VALUES = %w[true 1].freeze

    # DUAS chaves, e as duas precisam estar ligadas.
    #
    # OMIE_ALLOW_WRITES é a chave geral do servidor, e continua o que sempre
    # foi. `escrita_liberada` é por EMPRESA, e existe porque a trava única não
    # se sustenta com vários clientes: ligá-la para validar um liberaria a
    # gravação na contabilidade de todos os outros ao mesmo tempo.
    #
    # Sem tenant no contexto (tarefa de manutenção, console) só a chave geral
    # vale — quem roda ali sabe o que está fazendo.
    def self.writes_enabled?(tenant: Current.tenant)
      return false unless WRITE_ENABLED_VALUES.include?(ENV["OMIE_ALLOW_WRITES"].to_s.strip.downcase)

      return true if tenant.blank?

      Integracoes::Config.bool(PROVEDOR, :escrita_liberada, tenant: tenant)
    end

    def self.read_only_call?(call)
      READ_PREFIXES.any? { |prefix| call.to_s.start_with?(prefix) }
    end

    def initialize(app_key: nil, app_secret: nil, tenant: nil)
      @app_key_informada = app_key

      @app_secret_informado = app_secret

      @tenant = tenant
    end


    # A suíte roda com o mesmo ENV do desenvolvimento, então `configured?` é
    # verdadeiro e um serviço que monte o cliente real sairia para a rede — no
    # ERP do cliente. Ou o teste injeta um dublê, ou isto estoura.
    def self.network_allowed_in_test?
      %w[true 1].include?(ENV["OMIE_PERMITIR_REDE_EM_TESTE"].to_s.strip.downcase)
    end

    def request(endpoint, call, params = {})
      # Trava compartilhada com os demais clientes — ver RedeExterna.
      RedeExterna.bloquear!("o OMIE", call) unless self.class.network_allowed_in_test?

      guard_write!(call)

      body = {
        call: call,
        app_key: app_key,
        app_secret: app_secret,
        param: [params]
      }

      uri = uri_for(endpoint)

      # O parse entra no laço porque o erro de concorrência chega no corpo da
      # resposta, não como falha de transporte.
      with_retries do
        parse!(post(uri, body), call)
      end
    end

    private

    # Resolvidas a cada uso, e não na construção: o cliente costuma ser montado
    # antes de o tenant do contexto estar definido.
    def app_key
      @app_key_informada || Integracoes::Config.get(PROVEDOR, :app_key, tenant: tenant_efetivo)
    end

    def app_secret
      @app_secret_informado || Integracoes::Config.get(PROVEDOR, :app_secret, tenant: tenant_efetivo)
    end

    def tenant_efetivo
      @tenant || Current.tenant
    end

    def guard_write!(call)
      return if self.class.read_only_call?(call)

      # O tenant do CLIENTE, e não o do contexto da requisição: o ciclo
      # automático roda sem requisição, e é justamente ele que precisa
      # respeitar a liberação de cada empresa.
      return if self.class.writes_enabled?(tenant: tenant_efetivo)

      raise WriteBlocked,
            "Chamada de escrita '#{call}' bloqueada. Ligue 'Gravar no OMIE desta empresa' " \
            "em Configurações > OMIE, e confirme que OMIE_ALLOW_WRITES=true no servidor."
    end

    def uri_for(endpoint)
      URI.join(
        "#{BASE_URL}/",
        endpoint.to_s.delete_prefix("/")
      )
    end

    def with_retries
      attempt = 0

      begin
        attempt += 1

        yield
      rescue ConcurrentRequest
        raise if attempt >= MAX_ATTEMPTS

        sleep(CONCURRENCY_BACKOFF * attempt)

        retry
      rescue *RETRIABLE => e
        raise TransportError, "Falha de rede ao chamar Omie: #{e.class} #{e.message}" if attempt >= MAX_ATTEMPTS

        sleep(backoff_for(attempt))

        retry
      end
    end

    def post(uri, body)
      http = Net::HTTP.new(uri.host, uri.port)

      http.use_ssl = uri.scheme == "https"

      http.open_timeout = OPEN_TIMEOUT

      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Post.new(uri)

      request["Content-Type"] = "application/json"

      request.body = body.to_json

      http.request(request)
    end

    def backoff_for(attempt)
      2**(attempt - 1)
    end

    # O Omie responde 500 com corpo JSON para erros de negócio, então o
    # faultstring precisa ser inspecionado antes do código HTTP.
    def parse!(response, call)
      parsed = JSON.parse(response.body.to_s)

      if parsed.is_a?(Hash) && parsed["faultstring"].present?
        fault = parsed["faultstring"]

        raise ConcurrentRequest, "Omie ocupado em #{call}: #{fault}" if fault.match?(CONCURRENT_REQUEST)

        if fault.match?(REDUNDANT_CONSUMPTION)
          raise RedundantConsumption.new(
            "Omie bloqueou #{call} por consumo redundante — a mesma requisição foi repetida. #{fault}",
            retry_after: fault[/(\d+)\s*segundos?/, 1]&.to_i
          )
        end

        raise ApiError.new(
          "Erro Omie em #{call}: #{fault}",
          fault_code: parsed["faultcode"]
        )
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise ApiError.new(
          "Erro Omie em #{call}: HTTP #{response.code}"
        )
      end

      parsed
    rescue JSON::ParserError
      raise ApiError.new(
        "Resposta não-JSON do Omie em #{call}: HTTP #{response.code}"
      )
    end
  end
end
