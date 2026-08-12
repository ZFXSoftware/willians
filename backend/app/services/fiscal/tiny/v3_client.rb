module Fiscal
  module Tiny
    # Ponto de troca para a API v3 do Tiny (REST + OAuth 2.0).
    #
    # Deliberadamente não implementado: os nomes dos campos da v3 não foram
    # conferidos, e inventá-los repetiria o erro que já custou caro nas outras
    # integrações. A interface é a mesma da V2Client, então migrar é trocar
    # TINY_API_VERSION para v3 depois de preencher esta classe.
    #
    # O que falta confirmar na doc (api-docs.erp.olist.com):
    #   - caminho de pesquisa de notas fiscais
    #   - se o número do pedido do marketplace continua como `numero_ecommerce`
    #   - fluxo OAuth: URL de autorização, troca de code, validade do token
    class V3Client
      class NotImplemented < StandardError; end

      def initialize(token: nil)
        @token = token
      end

      def pesquisar_notas(**)
        raise NotImplemented,
              "API v3 do Tiny ainda não implementada. Use TINY_API_VERSION=v2 " \
              "ou confirme os campos da v3 em api-docs.erp.olist.com."
      end
    end
  end
end
