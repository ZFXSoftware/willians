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

  get "integracoes", to: "integracoes#index"

  get "divergencias", to: "divergencias#index"

  get "conciliacoes/registros", to: "conciliacoes/registros#index"

  namespace :integracoes do
    post   "mercado-livre/autorizar",   to: "mercado_livre#autorizar"
    get    "mercado-livre/callback",    to: "mercado_livre#callback"
    delete "mercado-livre/desconectar", to: "mercado_livre#desconectar"
  end

  post "/conciliacoes/processar", to: "conciliacoes#processar"
end
