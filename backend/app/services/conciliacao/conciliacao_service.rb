module Conciliacao
  class ConciliacaoService
    def initialize(data_inicio:, data_fim:)
      @data_inicio = data_inicio
      @data_fim    = data_fim
      @omie        = OmieClient.new
      @log_prefix  = "[ConciliacaoService]"
    end

    def processar!
      log "Iniciando conciliação #{@data_inicio} -> #{@data_fim}"

      ActiveRecord::Base.transaction do
        titulos = buscar_titulos_omie
        movimentos = buscar_movimentos_marketplace

        index_movimentos = indexar_movimentos(movimentos)

        titulos.each do |titulo|
          processar_titulo(titulo, index_movimentos)
        end
      end

      log "Conciliação finalizada com sucesso"
      true
    rescue => e
      log "Erro geral: #{e.message}"
      raise e
    end

    private

    # =========================
    # OMIE
    # =========================

    def buscar_titulos_omie
      log "Buscando títulos no OMIE"

      response = @omie.call(
        endpoint: "financas/contareceber/listar",
        body: {
          pagina: 1,
          registros_por_pagina: 500,
          apenas_importado_api: "N"
        }
      )

      response["conta_receber_cadastro"] || []
    end

    def baixar_titulo(titulo, valor, data)
      log "Baixando título #{titulo['codigo_lancamento']} com valor #{valor}"

      @omie.call(
        endpoint: "financas/contareceber/receber",
        body: {
          codigo_lancamento: titulo["codigo_lancamento"],
          valor_recebido: valor,
          data_recebimento: data
        }
      )
    end

    def criar_ajuste(valor, descricao)
      log "Criando ajuste: #{descricao} (#{valor})"

      @omie.call(
        endpoint: "financas/contapagar/incluir",
        body: {
          valor_documento: valor.abs,
          data_vencimento: Date.today.to_s,
          observacao: descricao
        }
      )
    end

    # =========================
    # MARKETPLACE (mock/pluggable)
    # =========================

    def buscar_movimentos_marketplace
      log "Buscando movimentos do marketplace"

      # TODO: substituir por integração real
      ConciliacaoRegistro
        .where(data: @data_inicio..@data_fim)
        .to_a
    end

    def indexar_movimentos(movimentos)
      movimentos.group_by { |m| m.external_id }
    end

    # =========================
    # CORE
    # =========================

    def processar_titulo(titulo, index_movimentos)
      external_id = extrair_external_id(titulo)

      movimentos = index_movimentos[external_id]

      if movimentos.blank?
        registrar_nao_encontrado(titulo)
        return
      end

      valor_omie = titulo["valor_documento"].to_f
      valor_marketplace = movimentos.sum(&:valor)

      if ja_conciliado?(titulo)
        log "Título #{titulo['codigo_lancamento']} já conciliado — pulando"
        return
      end

      if valores_batem?(valor_omie, valor_marketplace)
        conciliar_perfeito(titulo, valor_marketplace)
      else
        conciliar_com_diferenca(titulo, valor_omie, valor_marketplace)
      end
    end

    def extrair_external_id(titulo)
      # Ajusta aqui conforme seu padrão
      titulo["numero_documento_fiscal"] || titulo["numero_documento"]
    end

    def valores_batem?(v1, v2)
      (v1 - v2).abs < 0.01
    end

    def ja_conciliado?(titulo)
      ConciliacaoRegistro.exists?(
        omie_id: titulo["codigo_lancamento"],
        status: "conciliado"
      )
    end

    # =========================
    # TIPOS DE CONCILIAÇÃO
    # =========================

    def conciliar_perfeito(titulo, valor)
      baixar_titulo(titulo, valor, Date.today.to_s)

      salvar_registro(titulo, valor, valor, "conciliado")

      log "Conciliado OK #{titulo['codigo_lancamento']}"
    end

    def conciliar_com_diferenca(titulo, valor_omie, valor_marketplace)
      diferenca = valor_marketplace - valor_omie

      baixar_titulo(titulo, valor_marketplace, Date.today.to_s)

      criar_ajuste(
        diferenca,
        "Divergência conciliação título #{titulo['codigo_lancamento']}"
      )

      salvar_registro(
        titulo,
        valor_omie,
        valor_marketplace,
        "divergente",
        diferenca
      )

      log "Conciliado com divergência #{titulo['codigo_lancamento']}: #{diferenca}"
    end

    def registrar_nao_encontrado(titulo)
      salvar_registro(
        titulo,
        titulo["valor_documento"],
        0,
        "nao_encontrado"
      )

      log "Título sem correspondência #{titulo['codigo_lancamento']}"
    end

    # =========================
    # PERSISTÊNCIA
    # =========================

    def salvar_registro(titulo, valor_omie, valor_marketplace, status, diferenca = 0)
      ConciliacaoRegistro.create!(
        omie_id: titulo["codigo_lancamento"],
        external_id: extrair_external_id(titulo),
        valor_omie: valor_omie,
        valor_marketplace: valor_marketplace,
        diferenca: diferenca,
        status: status,
        data: Date.today
      )
    end

    # =========================
    # LOG
    # =========================

    def log(msg)
      Rails.logger.info "#{@log_prefix} #{msg}"
    end
  end
end