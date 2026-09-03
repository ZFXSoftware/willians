Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :auth do
    post   "register", to: "registrations#create"
    post   "login",    to: "sessions#create"
    delete "logout",   to: "sessions#destroy"
    get    "me",       to: "me#show"
  end

  get "painel", to: "painel#show"

  # Quem tem acesso à empresa.
  get    "equipe", to: "equipe#index"
  post   "equipe/convidar", to: "equipe#convidar"
  delete "equipe/convites/:id", to: "equipe#revogar"
  patch  "equipe/membros/:id", to: "equipe#alterar_papel"
  delete "equipe/membros/:id", to: "equipe#remover"

  # Recebimento do convite — público: quem abre ainda não tem conta.
  get  "convites/:token", to: "convites#show"
  post "convites/:token/aceitar", to: "convites#aceitar"

  get "integracoes", to: "integracoes#index"

  get "divergencias", to: "divergencias#index"

  # Contestação junto à plataforma (briefing 2.5).
  get  "divergencias/:id/contestacao", to: "divergencias#contestacao"
  post "divergencias/:id/contestar", to: "divergencias#contestar"
  post "divergencias/:id/resolver", to: "divergencias#resolver"

  # Transferências entre contas e pagamentos na plataforma (briefing 2.7).
  post "movimentacoes/transferir", to: "movimentacoes#transferir"
  post "movimentacoes/pagar", to: "movimentacoes#pagar"

  # Devoluções e disputas rastreáveis (briefing 2.8).
  get  "devolucoes", to: "devolucoes#index"
  post "devolucoes/rastrear", to: "devolucoes#rastrear"

  # Espelho da conta virtual das plataformas (briefing 2.4).
  get  "saldos", to: "saldos#index"
  post "saldos/conferir", to: "saldos#conferir"

  # O razão inteiro. O painel mostra só as últimas movimentações, e com
  # milhares de lançamentos isso não responde "e os outros?".
  get "lancamentos", to: "lancamentos#index"

  # O que o sistema executou, e como terminou. A fila viva fica no gateway.
  get "processos", to: "processos#index"

  get "conciliacoes/registros", to: "conciliacoes/registros#index"

  namespace :integracoes do
    post "mercado-livre/autorizar", to: "mercado_livre#autorizar"
    get  "mercado-livre/callback",  to: "mercado_livre#callback"

    post "shopee/autorizar", to: "shopee#autorizar"
    get  "shopee/callback",  to: "shopee#callback"

    post "amazon/autorizar", to: "amazon#autorizar"
    get  "amazon/callback",  to: "amazon#callback"

    # Chaves de API por tenant, no lugar do .env.
    post "sincronizar", to: "sincronizacoes#create"

    delete "contas/:id", to: "contas#destroy"

    post   "contas/:id/arquivar", to: "contas#arquivar"

    # Códigos do OMIE desta conta de marketplace. Uma empresa vende em vários
    # marketplaces, e cada um é um cliente/fornecedor e uma conta corrente
    # diferentes no OMIE — um campo único na tela da empresa não dá conta.
    put    "contas/:id/omie", to: "contas#omie"

    # Cadastros do OMIE para a tela escolher de uma lista, em vez de o usuário
    # copiar um código de um terminal.
    get    "omie/opcoes", to: "omie#opcoes"

    # De qual canal veio cada nota. O nome do intermediador vem da NF-e, mas o
    # que ele significa só quem opera sabe dizer.
    get    "canais", to: "canais#index"
    put    "canais", to: "canais#update"

    get    "configuracoes", to: "configuracoes#index"
    put    "configuracoes/:provedor", to: "configuracoes#update"
    delete "configuracoes/:provedor/:chave", to: "configuracoes#destroy"

    # Vale para qualquer plataforma.
    delete "desconectar", to: "conexoes#destroy"
  end

  # Notas fiscais do Tiny. Só escreve no nosso banco; levar ao OMIE é outro
  # passo, com trava própria.
  post "fiscal/notas/importar", to: "fiscal/notas#importar"

  # Simula por padrão: só grava com `aplicar` explícito, e ainda assim depende
  # da trava OMIE_ALLOW_WRITES.
  post "fiscal/notas/enviar-ao-omie", to: "fiscal/notas#enviar_ao_omie"

  post "/conciliacoes/processar", to: "conciliacoes#processar"
end
