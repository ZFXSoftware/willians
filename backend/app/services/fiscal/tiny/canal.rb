module Fiscal
  module Tiny
    # De qual canal veio a venda, pelo intermediador declarado na NF-e.
    #
    # Antes disso o InvoiceSync atribuía toda nota à única conta de marketplace
    # ativa da empresa. Numa amostra de 40 notas do cliente, 17 eram do Mercado
    # Livre e 23 não — Shopee, Amazon, Magalu e TikTok, todas viradas em pedido
    # do Mercado Livre e jogadas na conciliação de uma conta que nunca vai
    # repassar por elas.
    #
    # O nome do intermediador é o que o cliente escolheu usar, e nem sempre é o
    # do marketplace: nas vendas da Amazon está a marca dele, "Alma teen". Por
    # isso a tabela é EDITÁVEL por empresa — os padrões cobrem os canais de
    # nome óbvio, e o resto alguém mapeia uma vez.
    #
    # Nome que não está na tabela devolve nil, e nil não vira palpite: a nota
    # fica sem canal, contada e visível. Chutar aqui é o defeito que este
    # arquivo existe para consertar.
    module Canal
      PADROES = {
        "mercado livre" => "mercado_livre",
        "mercadolivre" => "mercado_livre",
        "mercado pago" => "mercado_livre",
        "meli" => "mercado_livre",
        "shopee" => "shopee",
        "amazon" => "amazon",
        "amazon servicos de varejo do brasil" => "amazon",
        "magalu" => "magalu",
        "magazine luiza" => "magalu",
        "tiktok" => "tiktok",
        "tiktok shop" => "tiktok"
      }.freeze

      # Onde a empresa guarda os nomes que só ela usa.
      CHAVE = "canais_por_intermediador".freeze

      def self.para(nome, tenant: nil)
        chave = normalizar(nome)

        return if chave.blank?

        do_tenant(tenant)[chave] || PADROES[chave]
      end

      # Minúsculas, sem acento e sem pontuação: "Mercado Livre", "MERCADO
      # LIVRE" e "Mercado-Livre" são o mesmo canal, e obrigar o cliente a
      # acertar a grafia seria transformar configuração em armadilha.
      def self.normalizar(nome)
        return if nome.blank?

        nome.to_s
            .unicode_normalize(:nfd)
            .gsub(/\p{Mn}/, "")
            .downcase
            .gsub(/[^a-z0-9]+/, " ")
            .strip
      end

      def self.do_tenant(tenant)
        return {} if tenant.blank?

        (tenant.metadata || {})[CHAVE].to_h.transform_keys { |k| normalizar(k) }
      end

      # Os nomes que apareceram nas notas e ninguém mapeou.
      #
      # É a lista de trabalho: enquanto um nome estiver aqui, as notas dele não
      # têm canal e não viram pedido.
      def self.nao_mapeados(tenant)
        Invoice
          .where(tenant_id: tenant.id)
          .where("invoices.metadata->'intermediador'->>'nome' IS NOT NULL")
          .distinct
          .pluck(Arel.sql("invoices.metadata->'intermediador'->>'nome'"))
          .reject { |nome| para(nome, tenant: tenant).present? }
          .sort
      end
    end
  end
end
