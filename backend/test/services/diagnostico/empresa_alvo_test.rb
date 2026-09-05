require "test_helper"

module Diagnostico
  # Uma tarefa de diagnóstico que escolhe a empresa errada não falha: ela
  # responde. `canais:reatribuir` rodou contra o "Tenant Demo" e disse "0
  # pedidos a corrigir" com milhares errados na empresa real — e quem lê um
  # diagnóstico acredita nele.
  class EmpresaAlvoTest < ActiveSupport::TestCase
    # `anunciar!` imprime de propósito; aqui só o efeito interessa.
    def silenciando
      original = $stdout

      $stdout = StringIO.new

      yield
    ensure
      $stdout = original
    end

    def configurar!(tenant)
      IntegrationSetting.create!(
        tenant: tenant, provider: "tiny", key: "token", value: "T-#{tenant.id}"
      )
    end

    test "com uma empresa configurada, escolhe ela" do
      demo = criar_tenant(nome: "Tenant Demo")
      real = criar_tenant(nome: "Cliente")

      configurar!(real)

      assert_equal real.id, EmpresaAlvo.escolher(nil).id
      assert_not_equal demo.id, EmpresaAlvo.escolher(nil).id
    end

    # Empresa de teste não tem chave nenhuma, então some sozinha da lista. Foi
    # `Tenant.order(:id).first` que a colocou de volta.
    test "empresa sem integração não entra na disputa" do
      criar_tenant(nome: "Tenant Demo")

      assert_empty EmpresaAlvo.candidatas
    end

    # Duas configuradas é ambiguidade real. Escolher a de menor id seria
    # exatamente o defeito que este arquivo existe para impedir.
    test "com mais de uma configurada, recusa em vez de chutar" do
      duas = [ criar_tenant(nome: "A"), criar_tenant(nome: "B") ]

      duas.each { |t| configurar!(t) }

      erro = assert_raises(EmpresaAlvo::Ambigua) { EmpresaAlvo.escolher(nil) }

      assert_includes erro.message, "TENANT="
      duas.each { |t| assert_includes erro.message, t.name }
    end

    test "TENANT explícito vence qualquer regra" do
      demo = criar_tenant(nome: "Tenant Demo")

      configurar!(criar_tenant(nome: "Cliente"))

      assert_equal demo.id, EmpresaAlvo.escolher(demo.id.to_s).id
    end

    test "TENANT inexistente é erro, e não silêncio" do
      assert_raises(EmpresaAlvo::NaoEncontrada) { EmpresaAlvo.escolher("999999") }
    end

    # Escolher a empresa sem torná-la corrente deixava as credenciais fora de
    # alcance: o token do Tiny é lido de `Current.tenant`, e a tarefa abortava
    # com "token não configurado" numa empresa que tem o token configurado.
    test "anunciar torna a empresa corrente" do
      tenant = criar_tenant

      Current.tenant = nil

      silenciando { EmpresaAlvo.anunciar!(tenant.id.to_s) }

      assert_equal tenant.id, Current.tenant&.id
    end

    test "sem nenhuma configurada, diz isso" do
      criar_tenant(nome: "Tenant Demo")

      assert_raises(EmpresaAlvo::NaoEncontrada) { EmpresaAlvo.escolher(nil) }
    end
  end
end
