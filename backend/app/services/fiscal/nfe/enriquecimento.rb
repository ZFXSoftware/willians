module Fiscal
  module Nfe
    # Busca o XML da NF-e e completa o bloco `fiscal` da nota com o que só o documento tem.
    #
    # O ERP entrega a visão dele; o XML é o documento. Medido em 2026-09-28 sobre as 7.395
    # notas do cliente, o que falta hoje:
    #
    #   natureza da operação   4.269 de 6.371 do Tiny · ZERO das 1.024 do Mercado Livre
    #   CSOSN                    830 de 7.395
    #   PIS, COFINS, vTotTrib    campo nem existe
    #
    # NÃO sobrescreve o que já está lá. O que veio do ERP fica, e o XML entra no que está
    # vazio — com uma exceção nomeada em `PREFERE_O_XML`. Trocar tudo pelo XML seria a
    # mudança de base que já me mordeu duas vezes hoje: a medição decide, não a preferência.
    #
    # Uma requisição por nota, então o lote é limitado e a recusa é GRAVADA: sem isso o
    # ciclo de cinco minutos bateria para sempre nas mesmas notas que o ERP nega.
    class Enriquecimento
      LOTE_PADRAO = 50

      LOG_PREFIX = "[Fiscal::Nfe]".freeze

      # O que o XML manda mesmo havendo valor do ERP.
      #
      # Só estes, e cada um por um motivo medido: o CST do ICMS porque o ERP não o entrega
      # (zero de 7.395) e porque ler `<CST>` solto do XML pegaria o do IPI; os dois de ST
      # porque é o ST que decide a conta da apuração, e ali um valor errado vira imposto
      # cobrado a menos.
      PREFERE_O_XML = %w[csts valor_icms_st base_icms_st].freeze

      # Onde a tentativa fica registrada, para não repetir o que não tem resposta.
      MARCA = "xml".freeze

      def initialize(tenant:, limite: LOTE_PADRAO, cliente_tiny: nil, contas: nil)
        @tenant = tenant

        @limite = limite.to_i.clamp(1, 500)

        @cliente_tiny = cliente_tiny

        @contas = contas
      end

      def call
        resumo = { lidas: 0, completadas: 0, recusadas: 0, sem_caminho: 0, erros: 0 }

        pendentes.each do |nota|
          resumo[:lidas] += 1

          xml = buscar(nota)

          if xml.blank?
            registrar!(nota, "sem_caminho", "não há de onde buscar o XML desta nota")

            resumo[:sem_caminho] += 1

            next
          end

          aplicar!(nota, Leitura.para(xml))

          resumo[:completadas] += 1
        rescue Leitura::NaoEhNfe => e
          # Recusa do ERP ou nota não autorizada: é resposta, e não erro a repetir.
          registrar!(nota, "recusado", e.message)

          resumo[:recusadas] += 1
        rescue StandardError => e
          registrar!(nota, "erro", "#{e.class}: #{e.message}")

          resumo[:erros] += 1
        end

        Rails.logger.info(
          "#{LOG_PREFIX} empresa ##{tenant.id}: #{resumo[:lidas]} nota(s) lidas, " \
          "#{resumo[:completadas]} completada(s), #{resumo[:recusadas]} recusada(s), " \
          "#{resumo[:sem_caminho]} sem caminho, #{resumo[:erros]} erro(s)"
        )

        resumo
      end

      private

      attr_reader :tenant, :limite

      # As notas que ainda não foram lidas do XML, mais novas primeiro.
      #
      # `metadata->'xml'` guarda a tentativa. Quem já tem — inclusive recusa — sai da fila,
      # senão o agendador voltaria nela a cada cinco minutos para receber o mesmo "não".
      def pendentes
        Invoice
          .where(tenant_id: tenant.id)
          .where("metadata->'xml' IS NULL")
          .order(issued_at: :desc)
          .limit(limite)
      end

      def buscar(nota)
        origem = nota.metadata.to_h["origem"].to_s

        return do_mercado_livre(nota) if origem.include?("mercado_livre")

        do_tiny(nota)
      end

      def do_tiny(nota)
        return if nota.external_id.blank?

        cliente_tiny.obter_xml(nota.external_id)
      rescue Fiscal::Tiny::V2Client::ApiError => e
        # "Nota Fiscal não autorizada" (código 34) é o caso medido: a nota existe no ERP e
        # não tem documento. Virar `NaoEhNfe` faz o chamador gravar a recusa em vez de
        # tentar de novo amanhã.
        raise Leitura::NaoEhNfe, e.message
      end

      # O `xml_location` devolveu JSON em 2 de 3 tentativas na medição, então o corpo é
      # conferido antes de ser tratado como documento.
      def do_mercado_livre(nota)
        caminho = nota.metadata.to_h.dig("mercado_livre", "xml_location")

        return if caminho.blank?

        conta = conta_de(nota)

        return if conta.blank?

        status, corpo, = cliente_ml(conta).resposta_crua(caminho)

        raise Leitura::NaoEhNfe, "o Mercado Livre respondeu HTTP #{status}" if status != 200

        corpo
      end

      def aplicar!(nota, lido)
        fiscal = nota.metadata.to_h["fiscal"].to_h

        completado = lido.each_with_object(fiscal.dup) do |(chave, valor), acc|
          next if valor.blank?

          # O que veio do ERP fica, salvo os campos que o XML manda.
          proximo = PREFERE_O_XML.include?(chave) || acc[chave].to_s.strip.blank?

          acc[chave] = valor if proximo
        end

        nota.update!(metadata: nota.metadata.to_h.merge(
          "fiscal" => completado,
          "xml" => { "situacao" => "lido", "lido_em" => Time.current, "chave" => lido["chave"] }.compact
        ))
      end

      def registrar!(nota, situacao, motivo)
        nota.update!(metadata: nota.metadata.to_h.merge(
          "xml" => { "situacao" => situacao, "motivo" => motivo.to_s.truncate(300), "tentado_em" => Time.current }
        ))
      end

      def cliente_tiny = @cliente_tiny ||= Fiscal::Tiny::V2Client.new

      def conta_de(nota)
        @contas ||= PlatformAccount
                      .where(tenant_id: tenant.id, platform: "mercado_livre", status: "active")
                      .to_a

        nota.order&.platform_account_id &&
          @contas.find { |c| c.id == nota.order.platform_account_id } || @contas.first
      end

      def cliente_ml(conta)
        @clientes_ml ||= {}

        @clientes_ml[conta.id] ||= Marketplace::MercadoLivre::OrdersClient.new(
          access_token: Marketplace::Credentials::TokenProvider.new(platform_account: conta).access_token,
          seller_id: conta.external_id
        )
      end
    end
  end
end
