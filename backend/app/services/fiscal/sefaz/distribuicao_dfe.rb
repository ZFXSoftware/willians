module Fiscal
  module Sefaz
    # Consulta o Web Service de Distribuição de DF-e do Ambiente Nacional.
    #
    # É o serviço da NT 2014.002, e a pergunta que este cliente existe para
    # responder ainda não tem resposta segura: ele devolve as notas que a
    # própria empresa EMITIU, ou só aquelas em que ela é destinatária? A nota
    # técnica fala em "autores da NF-e (emitente, destinatários,
    # transportadores e terceiros)", parte da documentação de mercado o trata
    # como serviço de documentos destinados, e as duas leituras convivem.
    #
    # Só uma chamada real decide, e é para isso que isto serve.
    #
    # A autenticação é TLS MÚTUO com o certificado A1 — o XML da consulta não
    # é assinado. Isso dispensa a pilha de XMLDSig.
    #
    # `Dfe` e não `DFe` porque o Zeitwerk deriva a constante do nome do
    # arquivo, e uma inflexão global para acertar a sigla afetaria o projeto
    # inteiro por causa de uma classe.
    class DistribuicaoDfe
      PRODUCAO = "https://www1.nfe.fazenda.gov.br/NFeDistribuicaoDFe/NFeDistribuicaoDFe.asmx".freeze

      HOMOLOGACAO = "https://hom1.nfe.fazenda.gov.br/NFeDistribuicaoDFe/NFeDistribuicaoDFe.asmx".freeze

      NS_WSDL = "http://www.portalfiscal.inf.br/nfe/wsdl/NFeDistribuicaoDFe".freeze

      NS_NFE = "http://www.portalfiscal.inf.br/nfe".freeze

      OPEN_TIMEOUT = 10

      READ_TIMEOUT = 60

      class Error < StandardError; end

      Documento = Struct.new(:nsu, :schema, :xml, keyword_init: true)

      Resposta = Struct.new(:codigo, :motivo, :ultimo_nsu, :max_nsu, :documentos, :bruto,
                            keyword_init: true)

      # `uf_autor` é o código IBGE da UF de quem consulta (35 = SP).
      def initialize(pkcs12:, cnpj:, uf_autor:, producao: true)
        @pkcs12 = pkcs12

        @cnpj = cnpj.to_s.gsub(/\D/, "")

        @uf_autor = uf_autor.to_s

        @producao = producao
      end

      def consultar(ultimo_nsu: 0)
        corpo = envelope(ultimo_nsu)

        resposta = executar(corpo)

        interpretar(resposta.body.to_s.dup.force_encoding("UTF-8"))
      end

      private

      attr_reader :pkcs12, :cnpj, :uf_autor, :producao

      def endpoint = producao ? PRODUCAO : HOMOLOGACAO

      # `tpAmb` 1 é produção. Consultar homologação com certificado de produção
      # devolve vazio — e vazio aqui seria lido como "não tem notas", que é a
      # conclusão errada mais fácil de tirar.
      def envelope(ultimo_nsu)
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <soap12:Envelope xmlns:soap12="http://www.w3.org/2003/05/soap-envelope">
            <soap12:Body>
              <nfeDistDFeInteresse xmlns="#{NS_WSDL}">
                <nfeDadosMsg>
                  <distDFeInt xmlns="#{NS_NFE}" versao="1.01">
                    <tpAmb>#{producao ? 1 : 2}</tpAmb>
                    <cUFAutor>#{uf_autor}</cUFAutor>
                    <CNPJ>#{cnpj}</CNPJ>
                    <distNSU><ultNSU>#{format('%015d', ultimo_nsu.to_i)}</ultNSU></distNSU>
                  </distDFeInt>
                </nfeDadosMsg>
              </nfeDistDFeInteresse>
            </soap12:Body>
          </soap12:Envelope>
        XML
      end

      def executar(corpo)
        RedeExterna.bloquear!("a SEFAZ")

        uri = URI.parse(endpoint)

        http = Net::HTTP.new(uri.host, uri.port)

        http.use_ssl = true

        http.open_timeout = OPEN_TIMEOUT

        http.read_timeout = READ_TIMEOUT

        # O certificado A1 autentica a conexão. Sem ele a SEFAZ recusa o
        # handshake, e o erro não menciona certificado — vem como falha de SSL.
        http.cert = pkcs12.certificate

        http.key = pkcs12.key

        req = Net::HTTP::Post.new(uri.request_uri)

        req["Content-Type"] = "application/soap+xml; charset=utf-8"

        req.body = corpo

        http.request(req)
      rescue OpenSSL::SSL::SSLError => e
        raise Error, "A SEFAZ recusou a conexão TLS: #{e.message}. " \
                     "Normalmente é certificado vencido, revogado ou de outro CNPJ."
      end

      # O `bruto` vai junto de propósito.
      #
      # Toda vez que um diagnóstico deste projeto escondeu a resposta crua, eu
      # conclui coisa errada com confiança. Aqui a resposta inteira fica
      # disponível para quem precisar olhar.
      def interpretar(xml)
        Resposta.new(
          codigo: extrair(xml, "cStat"),
          motivo: extrair(xml, "xMotivo"),
          ultimo_nsu: extrair(xml, "ultNSU"),
          max_nsu: extrair(xml, "maxNSU"),
          documentos: documentos(xml),
          bruto: xml
        )
      end

      def extrair(xml, tag)
        xml[%r{<#{tag}>([^<]*)</#{tag}>}, 1]
      end

      # Cada documento vem em base64 + gzip, com o NSU e o schema como
      # atributos.
      def documentos(xml)
        xml.scan(%r{<docZip([^>]*)>([^<]+)</docZip>}).map do |atributos, conteudo|
          Documento.new(
            nsu: atributos[/NSU="([^"]+)"/, 1],
            schema: atributos[/schema="([^"]+)"/, 1],
            xml: descompactar(conteudo)
          )
        end
      end

      def descompactar(base64)
        Zlib::GzipReader.new(StringIO.new(Base64.decode64(base64))).read.force_encoding("UTF-8")
      rescue StandardError => e
        "(não consegui descompactar: #{e.class})"
      end
    end
  end
end
