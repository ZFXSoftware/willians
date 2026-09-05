module Diagnostico
  # Sobre qual empresa a tarefa de diagnóstico vai agir.
  #
  # Existe porque eu já errei isto três vezes, em três tarefas diferentes:
  # `Tenant.order(:id).first` numa base que tem empresa de teste devolve a
  # empresa de teste, a tarefa roda contra ela, e o resultado sai limpo e
  # errado — "0 pedidos a corrigir" quando havia milhares.
  #
  # Silêncio é o pior desfecho possível num diagnóstico: quem o lê acredita.
  # Por isso aqui a empresa escolhida é sempre IMPRESSA junto com as outras
  # candidatas, e mais de uma candidata sem TENANT explícito é recusa, não
  # escolha automática.
  module EmpresaAlvo
    class Ambigua < StandardError; end

    class NaoEncontrada < StandardError; end

    # Empresa configurada é a que tem alguma integração ligada. As de teste
    # ficam de fora sozinhas, porque ninguém preencheu chave nelas.
    def self.candidatas
      Tenant.order(:id).select do |tenant|
        Current.with_tenant(tenant) do
          Fiscal::Tiny::Settings.configured?(tenant: tenant) || Omie::Client.configured?
        end
      end
    end

    def self.escolher(id_pedido = ENV["TENANT"])
      if id_pedido.present?
        tenant = Tenant.find_by(id: id_pedido)

        raise NaoEncontrada, "Não existe empresa ##{id_pedido}." if tenant.blank?

        return tenant
      end

      encontradas = candidatas

      raise NaoEncontrada, "Nenhuma empresa com Tiny ou OMIE configurado." if encontradas.empty?

      return encontradas.first if encontradas.one?

      raise Ambigua,
            "Mais de uma empresa configurada; diga qual com TENANT=<id>.\n" +
            encontradas.map { |t| "  ##{t.id} #{t.name}" }.join("\n")
    end

    # Para as tarefas: escolhe, anuncia, e aborta com a lista quando não dá
    # para decidir sozinho.
    def self.anunciar!(id_pedido = ENV["TENANT"])
      tenant = escolher(id_pedido)

      # Escolher a empresa e não a tornar CORRENTE deixava as credenciais fora
      # de alcance: o token do Tiny e o do OMIE são lidos de `Current.tenant`,
      # e a tarefa quebrava dizendo "token não configurado" numa empresa que
      # tem o token configurado. Cinco tarefas repetiam esta linha à mão e a
      # sexta esqueceu — é responsabilidade de quem escolhe a empresa.
      Current.tenant = tenant

      outras = Tenant.where.not(id: tenant.id).order(:id)

      puts "Empresa: ##{tenant.id} #{tenant.name}"

      if outras.any?
        puts "Outras no banco: #{outras.map { |t| "##{t.id} #{t.name}" }.join(', ')}"
        puts "(use TENANT=<id> para trocar)"
      end

      puts

      tenant
    rescue Ambigua, NaoEncontrada => e
      abort e.message
    end
  end
end
