module Integracoes
  # O que cada integração precisa para funcionar.
  #
  # Este catálogo é a fonte única: a tela de configurações é gerada a partir
  # dele, a resolução de valores usa o mesmo `env` como fallback, e um campo
  # novo aparece na interface sem mexer no frontend.
  module Catalogo
    Campo = Struct.new(
      :chave, :env, :rotulo, :ajuda, :tipo, :secreto, :obrigatorio, :opcoes, :padrao,
      keyword_init: true
    ) do
      def secreto? = !!secreto

      def obrigatorio? = !!obrigatorio
    end

    Provedor = Struct.new(:chave, :rotulo, :ajuda, :documentacao, :campos, keyword_init: true)

    def self.campo(chave, env:, rotulo:, ajuda: nil, tipo: :texto, secreto: false,
                   obrigatorio: false, opcoes: nil, padrao: nil)
      Campo.new(chave: chave.to_s, env: env, rotulo: rotulo, ajuda: ajuda, tipo: tipo,
                secreto: secreto, obrigatorio: obrigatorio, opcoes: opcoes, padrao: padrao)
    end

    PROVEDORES = {
      "omie" => Provedor.new(
        chave: "omie",
        rotulo: "OMIE",
        ajuda: "ERP onde os títulos são baixados. As chaves saem de um aplicativo " \
               "criado no próprio OMIE.",
        documentacao: "https://app.omie.com.br/desenvolvedor/",
        campos: [
          campo(:app_key, env: "OMIE_APP_KEY", rotulo: "App Key", obrigatorio: true,
                ajuda: "Aparece na tela do aplicativo, em Desenvolvedor → Meus aplicativos."),
          campo(:app_secret, env: "OMIE_APP_SECRET", rotulo: "App Secret", secreto: true,
                obrigatorio: true, ajuda: "Só é exibido uma vez, na criação do aplicativo."),

          # Códigos do plano de contas e cadastros DESTA empresa no OMIE. Não
          # são obrigatórios para ler; são obrigatórios para gravar, e cada um
          # é exigido pelo serviço que precisa dele, com a mensagem explicando
          # onde encontrá-lo.
          campo(:cliente_fornecedor_id, env: "OMIE_CLIENTE_FORNECEDOR_ID",
                rotulo: "Código do cliente/fornecedor",
                ajuda: "Quem aparece como cliente nos títulos que criamos. Normalmente é o " \
                       "próprio marketplace. Obtenha em ListarClientes."),
          campo(:conta_corrente_id, env: "OMIE_CONTA_CORRENTE_ID",
                rotulo: "Conta corrente",
                ajuda: "Onde as baixas caem. Obtenha em ListarContasCorrentes."),
          campo(:conta_corrente_destino_id, env: "OMIE_CONTA_CORRENTE_DESTINO_ID",
                rotulo: "Conta corrente de destino",
                ajuda: "Conta bancária para onde o marketplace deposita o saque. É o destino " \
                       "das transferências."),
          campo(:categoria_transitoria_receita, env: "OMIE_CATEGORIA_TRANSITORIA_RECEITA",
                rotulo: "Categoria transitória de receita",
                ajuda: "Onde entram os créditos sem vínculo com pedido ou nota fiscal. " \
                       "Uma categoria 1.x do seu plano de contas."),
          campo(:categoria_transitoria_despesa, env: "OMIE_CATEGORIA_TRANSITORIA_DESPESA",
                rotulo: "Categoria transitória de despesa",
                ajuda: "Onde entram os débitos sem vínculo com pedido ou nota fiscal. " \
                       "Uma categoria 2.x do seu plano de contas.")
        ]
      ),

      "mercado_livre" => Provedor.new(
        chave: "mercado_livre",
        rotulo: "Mercado Livre",
        ajuda: "Crie uma aplicação no portal de desenvolvedores e informe a mesma " \
               "URL de retorno que aparece abaixo.",
        documentacao: "https://developers.mercadolivre.com.br/devcenter",
        campos: [
          campo(:client_id, env: "ML_CLIENT_ID", rotulo: "Client ID", obrigatorio: true,
                ajuda: "Chamado de App ID no portal. Não é segredo: viaja na URL de autorização."),
          campo(:client_secret, env: "ML_CLIENT_SECRET", rotulo: "Client Secret",
                secreto: true, obrigatorio: true),
          campo(:use_pkce, env: "ML_USE_PKCE", rotulo: "Usar PKCE", tipo: :booleano,
                ajuda: "Ligue apenas se a aplicação estiver marcada como pública no portal."),
          campo(:url_contestacao, env: "ML_URL_CONTESTACAO", rotulo: "Link de contestação",
                tipo: :texto, padrao: "https://www.mercadolivre.com.br/vendas/{pedido}/detalhe",
                ajuda: "Para onde o botão Contestar leva. Use {pedido} e {nf} como " \
                       "marcadores. CONFIRA na sua conta: o caminho da central muda com o " \
                       "tempo e não é documentado publicamente.")
        ]
      ),

      "shopee" => Provedor.new(
        chave: "shopee",
        rotulo: "Shopee",
        ajuda: "As credenciais saem do Open Platform. A partner key assina cada " \
               "requisição e nunca viaja na URL.",
        documentacao: "https://open.shopee.com/",
        campos: [
          campo(:partner_id, env: "SHOPEE_PARTNER_ID", rotulo: "Partner ID", obrigatorio: true),
          campo(:partner_key, env: "SHOPEE_PARTNER_KEY", rotulo: "Partner Key",
                secreto: true, obrigatorio: true),
          campo(:region, env: "SHOPEE_REGION", rotulo: "Região", tipo: :opcao, padrao: "br",
                opcoes: [{ valor: "br", rotulo: "Brasil" },
                         { valor: "global", rotulo: "Global" },
                         { valor: "cn", rotulo: "China" }]),
          campo(:url_contestacao, env: "SHOPEE_URL_CONTESTACAO", rotulo: "Link de contestação",
                tipo: :texto, padrao: "https://seller.shopee.com.br/portal/sale/order",
                ajuda: "Para onde o botão Contestar leva. Use {pedido} e {nf} como " \
                       "marcadores. CONFIRA na sua conta: o caminho da central muda com o " \
                       "tempo e não é documentado publicamente.")
        ]
      ),

      "amazon" => Provedor.new(
        chave: "amazon",
        rotulo: "Amazon",
        ajuda: "Aplicativo registrado no Seller Central. Desde 2023 a SP-API não " \
               "usa mais chaves da AWS — só o Login with Amazon.",
        documentacao: "https://developer-docs.amazon.com/sp-api/",
        campos: [
          campo(:client_id, env: "AMAZON_CLIENT_ID", rotulo: "LWA Client ID", obrigatorio: true),
          campo(:client_secret, env: "AMAZON_CLIENT_SECRET", rotulo: "LWA Client Secret",
                secreto: true, obrigatorio: true),
          campo(:app_id, env: "AMAZON_APP_ID", rotulo: "Application ID", obrigatorio: true,
                ajuda: "Começa com amzn1.sp.solution. Vai na URL de consentimento do vendedor."),
          campo(:region, env: "AMAZON_REGION", rotulo: "Região", tipo: :opcao, padrao: "na",
                opcoes: [{ valor: "na", rotulo: "América do Norte (inclui Brasil)" },
                         { valor: "eu", rotulo: "Europa" },
                         { valor: "fe", rotulo: "Extremo Oriente" }]),
          campo(:app_draft, env: "AMAZON_APP_DRAFT", rotulo: "Aplicativo em rascunho",
                tipo: :booleano,
                ajuda: "Enquanto o app não é publicado, a autorização exige version=beta. " \
                       "Desligue depois de publicar."),
          campo(:url_contestacao, env: "AMAZON_URL_CONTESTACAO", rotulo: "Link de contestação",
                tipo: :texto, padrao: "https://sellercentral.amazon.com.br/orders-v3/order/{pedido}",
                ajuda: "Para onde o botão Contestar leva. Use {pedido} e {nf} como " \
                       "marcadores. CONFIRA na sua conta: o caminho da central muda com o " \
                       "tempo e não é documentado publicamente.")
        ]
      ),

      "tiny" => Provedor.new(
        chave: "tiny",
        rotulo: "Tiny (Olist)",
        ajuda: "É de onde vêm as NF-e. O token fica em Extensões → Token API → " \
               "Configurações → E-commerce.",
        documentacao: "https://tiny.com.br/ajuda/api",
        campos: [
          campo(:token, env: "TINY_TOKEN", rotulo: "Token da API", secreto: true, obrigatorio: true)
        ]
      )
    }.freeze

    def self.provedores = PROVEDORES.values

    def self.provedor(chave) = PROVEDORES[chave.to_s]

    def self.provedor!(chave)
      provedor(chave) || raise(ArgumentError, "Integração desconhecida: #{chave}")
    end

    def self.campos(provedor_chave) = provedor!(provedor_chave).campos

    def self.campo_de(provedor_chave, chave)
      campos(provedor_chave).find { |c| c.chave == chave.to_s }
    end

    def self.campo_de!(provedor_chave, chave)
      campo_de(provedor_chave, chave) ||
        raise(ArgumentError, "Campo desconhecido em #{provedor_chave}: #{chave}")
    end
  end
end
