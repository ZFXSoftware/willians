module Marketplace
  module MercadoLivre
    module Settings
      PLATFORM = "mercado_livre".freeze

      # Inclui o prefixo /api porque o nginx é quem o remove antes de chegar no
      # Rails — a URL registrada no app do ML é a pública, não a interna.
      CALLBACK_PATH = "/api/integracoes/mercado-livre/callback".freeze

      RETURN_PATH = "/integracoes".freeze

      class MissingPublicUrl < StandardError; end

      # Precisa bater EXATAMENTE com a redirect_uri cadastrada no app do ML.
      def self.redirect_uri
        ENV["ML_REDIRECT_URI"].presence || build(CALLBACK_PATH)
      end

      # Para onde o navegador volta depois da autorização.
      def self.return_url(status:, message: nil)
        uri = URI.parse(build(RETURN_PATH))

        uri.query = URI.encode_www_form(
          { integracao: PLATFORM, status: status, mensagem: message }.compact
        )

        uri.to_s
      end

      def self.public_url
        ENV["APP_PUBLIC_URL"].presence
      end

      def self.build(path)
        base = public_url

        if base.blank?
          raise MissingPublicUrl,
                "APP_PUBLIC_URL não configurado. O OAuth do Mercado Livre exige uma URL " \
                "pública HTTPS fixa — suba o túnel e preencha o .env."
        end

        URI.join(base, path).to_s
      end
    end
  end
end
