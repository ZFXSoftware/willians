# Fechado num módulo porque `def` no topo ou dentro de um bloco de rake define
# método em Object: todos os arquivos de tarefa dividem esse espaço, e um nome
# genérico como `medir` colide com o de outro arquivo. Aconteceu hoje com
# `valores_de`, e só apareceu na VPS, com os dois carregados juntos.
module ParcelasEVendasAntigas
  module_function

  # O que o relatório diz sobre um grupo de vendas.
  def medir(grupo, linhas)
    dados = {
      descricoes: Hash.new(0),
      parcelas: Hash.new(0),
      atrasos: [],
      meses: Hash.new(0),
      sem_linha: 0
    }

    grupo.each do |unidade|
      cru = linhas[unidade.external_id]

      next dados[:sem_linha] += 1 if cru.blank?

      dados[:descricoes][cru["DESCRIPTION"].presence || "(vazio)"] += 1

      dados[:parcelas][cru["INSTALLMENTS"].presence || "(ausente)"] += 1

      aprovado = cru["TRANSACTION_APPROVAL_DATE"]

      liberado = cru["DATE"]

      next if aprovado.blank? || liberado.blank?

      dados[:atrasos] << (Date.parse(liberado) - Date.parse(aprovado)).to_i

      dados[:meses][Date.parse(aprovado).strftime("%Y-%m")] += 1
    end

    dados
  end

  def imprimir(rotulo, grupo, dados)
    puts "#{rotulo} (#{grupo.size}):"

    puts format("  sem a linha guardada: %d", dados[:sem_linha]) if dados[:sem_linha].positive?

    puts "  DESCRIPTION:  #{dados[:descricoes].sort_by { |_, q| -q }.first(5).to_h.inspect}"

    puts "  INSTALLMENTS: #{dados[:parcelas].sort_by { |_, q| -q }.first(6).to_h.inspect}"

    if dados[:atrasos].any?
      ordenados = dados[:atrasos].sort

      puts format("  dias entre aprovação e liberação: mínimo %d · mediana %d · máximo %d",
                  ordenados.first, ordenados[ordenados.size / 2], ordenados.last)
    end

    if dados[:meses].any?
      puts "  mês da APROVAÇÃO da venda:"

      dados[:meses].sort.each { |mes, quantas| puts format("    %-9s %d", mes, quantas) }
    end

    puts
  end
end

namespace :conciliacao do
  desc "As vendas sem nota são parcelas ou vendas antigas? (SOMENTE LEITURA)"
  task parcelas_e_vendas_antigas: :environment do
    # Hipótese do usuário: venda sem nota fiscal é impossível, então as notas
    # existem em algum lugar — e podem ser PARCELAS de vendas antigas.
    #
    # A consequência que eu não tinha considerado: venda parcelada tem o dinheiro
    # liberado em vários repasses, e cada liberação vira um recebível nosso. Se a
    # nota ficou ligada a um deles, os outros aparecem como "sem nota" sendo a
    # MESMA venda — e aí não falta documento, falta vínculo.
    #
    # Duas colunas decidem, e as duas passaram a ser guardadas:
    #   DESCRIPTION                "INSTALLMENT" marca liberação de parcela
    #   TRANSACTION_APPROVAL_DATE  quando a venda foi aprovada, não liberada
    #
    # Compara sempre as DUAS populações. Medir só o lado suspeito foi o que
    # derrubou quatro explicações minhas nesta investigação.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    unidades = ReceivableUnit.where(tenant_id: tenant.id).includes(:order, :invoice).to_a

    abort "Nenhuma venda no banco." if unidades.none?

    sem_nota, com_nota = unidades.partition { |u| u.invoice_id.blank? }

    puts "Vendas: #{unidades.size} · com nota #{com_nota.size} · sem nota #{sem_nota.size}"
    puts

    # A mesma venda, liberada em partes: se o pedido tem outro recebível COM
    # nota, o documento existe e o que falta é vínculo.
    pedidos_com_nota = com_nota.filter_map(&:order_id).to_set

    partidas = sem_nota.select { |u| u.order_id.present? && pedidos_com_nota.include?(u.order_id) }

    puts "Sem nota cujo MESMO pedido tem outro recebível COM nota: #{partidas.size}"
    puts "  (a nota existe; falta o vínculo, não o documento)"
    puts

    if partidas.any?
      puts "  Exemplos:"

      partidas.first(5).each do |unidade|
        irmas = com_nota.select { |o| o.order_id == unidade.order_id }

        puts format("    pedido %-20s esta parte R$ %8.2f · %d irmã(s) com NF %s",
                    unidade.order&.external_id, unidade.gross_amount.to_d, irmas.size,
                    irmas.first&.invoice&.number)
      end

      puts
    end

    linhas = FinancialEntry
               .where(tenant_id: tenant.id)
               .where("jsonb_typeof(raw_payload) = 'object'")
               .pluck(:external_id, :raw_payload)
               .to_h

    puts "Linhas do relatório guardadas: #{linhas.size}"
    puts

    [ [ "SEM nota", sem_nota ], [ "COM nota", com_nota ] ].each do |rotulo, grupo|
      ParcelasEVendasAntigas.imprimir(rotulo, grupo, ParcelasEVendasAntigas.medir(grupo, linhas))
    end

    puts "Como ler:"
    puts "  DESCRIPTION = INSTALLMENT     -> liberação de parcela, não venda nova."
    puts "  aprovação em mês muito antes  -> venda antiga; a nota é do mês dela e"
    puts "                                   pode estar fora da janela importada."
    puts "  mesmo pedido com irmã com NF  -> a nota existe: falta vínculo."
    puts
    puts "Nada foi gravado."
  end
end
