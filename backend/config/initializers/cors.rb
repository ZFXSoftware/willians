# Be sure to restart your server when you modify this file.
#
# O frontend roda em outra origem (Vite em :5173/:3050) e conversa com esta API
# por Authorization: Bearer. Sem CORS o browser bloqueia a chamada antes de sair.
#
# Autenticação é por header, não por cookie — por isso `credentials: false`, o
# que também permite listar origens explicitamente sem risco de CSRF via cookie.

DEFAULT_ORIGINS = %w[
  http://localhost:5173
  http://localhost:3050
  http://127.0.0.1:5173
  http://127.0.0.1:3050
].freeze

allowed_origins =
  ENV["FRONTEND_ORIGINS"].to_s.split(",").map(&:strip).reject(&:blank?).presence ||
  DEFAULT_ORIGINS

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(*allowed_origins)

    resource "*",
             headers: :any,
             methods: [:get, :post, :put, :patch, :delete, :options, :head],
             expose: ["Authorization"],
             credentials: false
  end
end
