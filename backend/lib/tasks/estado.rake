desc "Mostra, por empresa, o que está conectado e o que já foi importado (SOMENTE LEITURA)"
task estado: :environment do
  # Existe porque toda dúvida de operação ("cadê minhas chaves?", "a conta
  # conectou?", "por que não importou nada?") vinha sendo respondida colando um
  # `rails runner` improvisado no console da VPS. Improviso não é repetível nem
  # auditável.
  #
  # NUNCA imprime valor de chave, token ou segredo — só se existe e se está
  # utilizável. Este diagnóstico vai parar em print de tela e em conversa.
  imprimir_ambiente

  Tenant.order(:id).each do |tenant|
    puts
    puts "=" * 72
    puts "EMPRESA ##{tenant.id} — #{tenant.name}"
    puts "=" * 72

    imprimir_membros(tenant)
    imprimir_chaves(tenant)
    imprimir_contas(tenant)
  end

  puts
  puts "Nada foi gravado. Este comando só lê."
  puts
end

# --- Blocos do relatório ------------------------------------------------------

def imprimir_ambiente
  puts
  puts "=" * 72
  puts "AMBIENTE"
  puts "=" * 72

  linha "RAILS_ENV:", Rails.env
  linha "URL pública:", ENV["APP_PUBLIC_URL"].presence || "NÃO configurada"

  # A causa nº 1 de OAuth que volta com erro é esta URL não bater, caractere a
  # caractere, com a cadastrada no painel do marketplace.
  linha "Callback do ML:", callback_do_ml
  puts "  #{' ' * 28}^ idêntica à cadastrada no painel do Mercado Livre?"

  linha "OMIE configurado:", sim_nao(Omie::Client.configured?)
  linha "Escrita no OMIE:",
        Omie::Client.writes_enabled? ? "HABILITADA (cuidado!)" : "bloqueada"

  # Se a simulação estiver ligada e uma conta cair no provider falso, entram
  # lançamentos fictícios no razão com cara de reais. Merece destaque.
  simulacao = ENV["MARKETPLACE_SIMULATION"].to_s.strip.downcase

  linha "Simulação de marketplace:",
        %w[true 1].include?(simulacao) ? "LIGADA — pode gerar dado fictício" : "desligada"
end

def imprimir_membros(tenant)
  membros = TenantUser.where(tenant_id: tenant.id).includes(:user).order(:id)

  puts "  Membros (#{membros.size}):"

  membros.each { |m| puts format("    %-44s %s", m.user&.email, m.role) }
end

def imprimir_chaves(tenant)
  puts
  puts "  Chaves de integração (só os nomes — valores nunca são impressos):"

  chaves = IntegrationSetting.where(tenant_id: tenant.id).order(:provider, :key)

  if chaves.empty?
    puts "    nenhuma. Sem elas o OAuth nem começa: Configurações > Integrações."
    return
  end

  chaves.group_by(&:provider).each do |provider, linhas|
    puts format("    %-16s %d chave(s), %s: %s",
                provider, linhas.size, preenchidas(linhas), linhas.map(&:key).join(", "))
  end
end

# Contar as preenchidas exige DECIFRAR. Se a chave de criptografia do ambiente
# estiver errada, isso levanta — e um diagnóstico que quebra é inútil
# justamente na hora em que ele é necessário. Então a falha vira resposta.
def preenchidas(linhas)
  "#{linhas.count { |l| l.value.present? }} preenchida(s)"
rescue ActiveRecord::Encryption::Errors::Base => e
  "ILEGÍVEIS (#{e.class.name.demodulize}) — a chave de criptografia deste " \
  "ambiente não é a que gravou os valores"
end

def imprimir_contas(tenant)
  contas = tenant.platform_accounts.includes(:marketplace_credential).order(:id)

  puts
  puts "  Contas de marketplace (#{contas.size}):"

  if contas.empty?
    puts "    nenhuma. Conecte em Integrações > Disponíveis para conectar."
    return
  end

  contas.each { |conta| imprimir_conta(conta) }
end

def imprimir_conta(conta)
  puts
  puts "    ── conta ##{conta.id} · #{conta.platform} · #{conta.name}"

  linha_conta "id na plataforma:", conta.external_id.presence || "—"
  linha_conta "situação:", conta.status

  imprimir_credencial(conta.marketplace_credential)

  linha_conta "pronta para sincronizar:", pronta_para_sincronizar(conta)
  linha_conta "última sincronização:", quando(conta.last_synced_at)

  # "pendente" é o marketplace ainda preparando o dado: nem sucesso nem falha.
  linha_conta "desfecho:", conta.last_sync_status if conta.last_sync_status.present?

  linha_conta "mensagem:", conta.last_sync_error if conta.last_sync_error.present?

  imprimir_volumes(conta)
end

def imprimir_credencial(credencial)
  if credencial.blank?
    linha_conta "credencial:", "nenhuma — a conta nunca passou pelo OAuth"
    return
  end

  linha_conta "credencial:", credencial.status
  linha_conta "vendedor no marketplace:", credencial.external_user_id.presence || "—"
  linha_conta "token vence:", quando(credencial.expires_at)
  linha_conta "token utilizável:", sim_nao(credencial.usable?)

  return if credencial.refresh_error.blank?

  linha_conta "falha ao renovar:", credencial.refresh_error.truncate(120)
end

def imprimir_volumes(conta)
  entradas = conta.financial_entries

  total = entradas.count

  linha_conta "importado:",
              format("pedidos=%d  lançamentos=%d  recebíveis=%d",
                     conta.orders.count, total, conta.receivable_units.count)

  return if total.zero?

  linha_conta "evento mais recente:", quando(entradas.maximum(:occurred_at))

  linha_conta "conciliação:",
              format("conciliados=%d  divergentes=%d",
                     entradas.where(reconciled: true).count,
                     entradas.where(has_divergence: true).count)
end

# --- Auxiliares ---------------------------------------------------------------

def linha(rotulo, valor)
  puts format("  %-28s %s", rotulo, valor)
end

def linha_conta(rotulo, valor)
  puts format("       %-26s %s", rotulo, valor)
end

def sim_nao(valor)
  valor ? "sim" : "NÃO"
end

def callback_do_ml
  Marketplace::MercadoLivre::Settings.redirect_uri
rescue Marketplace::MercadoLivre::Settings::MissingPublicUrl
  "indisponível (sem URL pública)"
end

# O mesmo teste que o SincronizacaoService faz antes de chamar a API: se der
# "não", a sincronização é ignorada de propósito, e não quebrada.
def pronta_para_sincronizar(conta)
  nome = Marketplace::Ingestors::MarketplaceIngestor::PROVIDERS[conta.platform.to_s]

  return "NÃO — plataforma sem integração implementada" if nome.blank?

  nome.constantize.configured?(conta) ? "sim" : "NÃO — falta autorizar pelo OAuth"
rescue StandardError => e
  "erro ao verificar: #{e.class}"
end

def quando(tempo)
  return "nunca" if tempo.blank?

  distancia = distancia_em_palavras((Time.current - tempo).abs)

  relativo = tempo > Time.current ? "em #{distancia}" : "há #{distancia}"

  "#{tempo.in_time_zone.strftime('%d/%m/%Y %H:%M')} (#{relativo})"
end

# O `distance_of_time_in_words` do Rails responde em inglês — o app só tem o
# locale en. Para um relatório que o cliente lê, isso não serve.
def distancia_em_palavras(segundos)
  case segundos
  when 0...60 then "menos de um minuto"
  when 60...3600 then plural(segundos / 60, "minuto")
  when 3600...86_400 then plural(segundos / 3600, "hora")
  else plural(segundos / 86_400, "dia")
  end
end

def plural(quantidade, unidade)
  quantidade = quantidade.round

  "#{quantidade} #{unidade}#{'s' if quantidade != 1}"
end
