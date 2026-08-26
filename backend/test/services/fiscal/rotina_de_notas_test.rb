require "test_helper"

module Fiscal
  # Trazer as notas do Tiny e levá-las ao OMIE é FUNÇÃO do sistema, não
  # migração de uma vez. Enquanto dependia de alguém apertar um botão, cada
  # cliente precisava de uma pessoa lembrando de entrar e clicar.
  #
  # Mas automatizar escrita na contabilidade de alguém exige travas que a ação
  # manual não precisa — e são elas que estes testes prendem.
  class RotinaDeNotasTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)

      @tenant.update!(metadata: { "omie_conta_corrente_id" => "777" })
    end

    def configurar(valores)
      valores.each do |chave, valor|
        IntegrationSetting.create!(tenant: @tenant, provider: "omie", key: chave.to_s, value: valor)
      end

      Current.settings_cache.clear if Current.integration_settings
    end

    def nota_pronta(numero: "850512", emitida_em: Date.current)
      pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PED-#{numero}")

      nota = criar_nota(tenant: @tenant, pedido: pedido, numero: numero, valor: 150)

      nota.update!(
        operation_type: :sale, issued_at: emitida_em,
        metadata: { "comprador_nome" => "Sirley", "comprador_documento" => "55788696291" }
      )

      nota
    end

    def enviar(**args)
      Financeiro::EnvioDeNotasAoOmie.new(
        tenant: @tenant, client: Object.new, pausa: 0, automatico: true, **args
      ).call
    end

    # ------------------------------------------------------- marco inicial

    # Sem data de corte, o primeiro ciclo de um cliente novo tentaria mandar o
    # histórico inteiro — inclusive o que o sistema antigo já lançou.
    test "o ciclo automático se recusa a rodar sem data de corte" do
      nota_pronta

      erro = assert_raises(Financeiro::EnvioDeNotasAoOmie::SemMarcoInicial) { enviar }

      assert_includes erro.message, "a partir de"
    end

    test "nota anterior à data de corte fica de fora" do
      configurar(envio_a_partir_de: Date.current.to_s)

      nota_pronta(numero: "1", emitida_em: Date.current - 10)
      nota_pronta(numero: "2", emitida_em: Date.current)

      assert_equal 1, enviar[:previstas]
    end

    # ---------------------------------------------------- trava por empresa

    # A trava era do SERVIDOR inteiro: ligá-la para validar UM cliente liberaria
    # a gravação na contabilidade de todos os outros ao mesmo tempo.
    #
    # São duas chaves agora, e as duas precisam estar ligadas.
    test "empresa não liberada não grava, mesmo com a chave do servidor ligada" do
      com_env("OMIE_ALLOW_WRITES" => "true") do
        assert_not Omie::Client.writes_enabled?(tenant: @tenant)
      end
    end

    test "empresa liberada não grava se a chave do servidor estiver desligada" do
      configurar(escrita_liberada: "true")

      com_env("OMIE_ALLOW_WRITES" => nil) do
        assert_not Omie::Client.writes_enabled?(tenant: @tenant)
      end
    end

    # Simular a pedido NÃO é estar travado.
    #
    # Sem essa distinção, a simulação que o botão faz de propósito voltava
    # marcada como "escrita bloqueada": a tela dizia que nada foi gravado
    # porque estava travado — com as duas chaves ligadas — e escondia os
    # botões de envio, que só aparecem quando não há trava.
    test "simulação pedida com tudo liberado não se diz bloqueada" do
      # Com as chaves do OMIE, senão o cliente cai no dublê e o motivo vira
      # "sem credencial", que é outro caso.
      configurar(app_key: "K", app_secret: "S", escrita_liberada: "true")

      com_env("OMIE_ALLOW_WRITES" => "true") do
        _, dry_run, motivo = Financeiro::EscritaNoOmie.preparar(
          tenant: @tenant, client: nil, dry_run: true
        )

        assert dry_run, "foi pedido para simular"
        assert_nil motivo, "mas não por estar travado"
      end
    end

    test "simulação forçada pela trava se diz bloqueada" do
      configurar(app_key: "K", app_secret: "S")

      com_env("OMIE_ALLOW_WRITES" => "true") do
        _, dry_run, motivo = Financeiro::EscritaNoOmie.preparar(
          tenant: @tenant, client: nil, dry_run: false
        )

        assert dry_run, "a trava vence o pedido de gravar"
        assert_equal :escrita_bloqueada, motivo
      end
    end

    test "as duas ligadas liberam" do
      configurar(escrita_liberada: "true")

      com_env("OMIE_ALLOW_WRITES" => "true") do
        assert Omie::Client.writes_enabled?(tenant: @tenant)
      end
    end

    # Quem trouxe as chaves do OMIE precisa continuar protegido pela trava
    # mesmo quando o serviço acha que pode gravar.
    test "o cliente real recusa a chamada de escrita da empresa não liberada" do
      com_env("OMIE_ALLOW_WRITES" => "true") do
        cliente = Omie::Client.new(app_key: "k", app_secret: "s", tenant: @tenant)

        assert_raises(Omie::Client::WriteBlocked) do
          cliente.send(:guard_write!, "IncluirContaReceber")
        end
      end
    end

    # ------------------------------------------------- parar depois de falhar

    # Se o OMIE está recusando, insistir de hora em hora não conserta nada e
    # ainda enche a contabilidade de tentativa.
    test "três falhas seguidas param o ciclo automático" do
      configurar(envio_a_partir_de: Date.current.to_s)

      @tenant.update!(metadata: @tenant.metadata.merge(
        "omie_envio_saude" => { "falhas_seguidas" => 3, "ultimo_erro" => "OMIE fora do ar" }
      ))

      erro = assert_raises(Financeiro::EnvioDeNotasAoOmie::MuitasFalhas) { enviar }

      assert_includes erro.message, "OMIE fora do ar"
    end

    test "uma execução sem falha zera a contagem" do
      configurar(envio_a_partir_de: Date.current.to_s, escrita_liberada: "true")

      @tenant.update!(metadata: @tenant.metadata.merge(
        "omie_envio_saude" => { "falhas_seguidas" => 2 }
      ))

      espiao = Object.new

      espiao.define_singleton_method(:request) { |*, **| { "codigo_lancamento_omie" => 1 } }

      nota_pronta

      com_env("OMIE_ALLOW_WRITES" => "true") do
        Financeiro::EnvioDeNotasAoOmie.new(
          tenant: @tenant, client: espiao, pausa: 0, automatico: true, dry_run: false
        ).call
      end

      assert_equal 0, @tenant.reload.metadata.dig("omie_envio_saude", "falhas_seguidas")
    end

    # ------------------------------------------------------------- a rotina

    test "empresa sem Tiny configurado é ignorada, não quebra o ciclo" do
      resumo = RotinaDeNotas.new(tenant: @tenant).call

      assert_includes resumo[:ignorada].to_s, "Tiny"
    end
  end
end
