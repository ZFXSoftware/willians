require "test_helper"

module Marketplace
  # O ML entrega access_token de 6h e refresh_token de uso único: errar a
  # renovação desconecta a conta do cliente e exige reautorização manual.
  class MercadoLivreOauthTest < ActiveSupport::TestCase
    ML = Marketplace::MercadoLivre

    setup do
      @tenant = criar_tenant
      @usuario = criar_usuario(tenant: @tenant)
      @falso = OauthFalso.new
      @publico = "https://teste.ngrok-free.dev"
      # O OAuth do ML recusa subir sem URL pública, tanto na autorização quanto
      # no callback (o redirect_uri tem que ser idêntico nas duas pontas).
      @env_anterior = ENV["APP_PUBLIC_URL"]
      ENV["APP_PUBLIC_URL"] = @publico
    end

    teardown do
      @env_anterior.nil? ? ENV.delete("APP_PUBLIC_URL") : ENV["APP_PUBLIC_URL"] = @env_anterior
    end

    def autorizar
      ML::Authorization.new(tenant: @tenant, user: @usuario, client: @falso).call
    end

    def conectar
      resultado = autorizar

      ML::Callback.new(code: "CODE-XYZ", state: resultado[:state], client: @falso).call
    end

    # -------------------------------------------------------------- autorização

    test "state é curto, amarrado ao usuário e vai na URL" do
      resultado = autorizar
      state = OauthState.find_by!(state: resultado[:state])

      assert_nil state.consumed_at
      assert_equal @tenant.id, state.tenant_id
      assert_equal @usuario.id, state.user_id
      assert_operator state.expires_at, :<=, 20.minutes.from_now
      assert_includes resultado[:authorization_url], resultado[:state]
    end

    test "redirect_uri é a URL pública com o prefixo /api" do
      resultado = autorizar
      esperado = "#{@publico}/api/integracoes/mercado-livre/callback"

      assert_equal esperado, ML::Settings.redirect_uri

      assert_includes resultado[:authorization_url], CGI.escape(esperado)
    end

    # ------------------------------------------------------------------ callback

    test "callback troca o código e conecta a conta" do
      credencial = conectar

      assert_equal ["CODE-XYZ"], @falso.exchange_calls
      assert credencial.connected?
      assert_equal "AT-1", credencial.access_token
      assert_in_delta 21_600, credencial.expires_at - Time.current, 700
      assert_equal @tenant.id, credencial.tenant_id
      assert_equal "555000111", credencial.platform_account.external_id
      assert_equal "mercado_livre", credencial.platform_account.platform
    end

    # A tela de Integrações oferece "Conectar" para plataforma que ainda não tem
    # conta nenhuma, e é assim que a PRIMEIRA conta nasce. Cadastrar à mão antes
    # criaria um registro sem identificador do vendedor, que o callback
    # duplicaria.
    test "a primeira conta nasce do próprio callback" do
      assert_equal 0, @tenant.platform_accounts.count

      credencial = conectar

      contas = @tenant.platform_accounts.reload

      assert_equal 1, contas.count
      assert_equal credencial.platform_account_id, contas.first.id
      assert contas.first.active?
    end

    test "reconectar a mesma loja reaproveita a conta, não cria outra" do
      primeira = conectar

      segunda = ML::Callback.new(
        code: "CODE-XYZ", state: autorizar[:state], client: @falso
      ).call

      assert_equal 1, @tenant.platform_accounts.reload.count
      assert_equal primeira.platform_account_id, segunda.platform_account_id
    end

    test "token não fica em claro na coluna" do
      credencial = conectar

      bruto = ActiveRecord::Base.connection.select_value(
        "SELECT access_token FROM marketplace_credentials WHERE id = #{credencial.id}"
      ).to_s

      refute_includes bruto, "AT-1", "token gravado sem cifra"
      assert bruto.start_with?("{"), "esperado envelope cifrado, veio #{bruto[0, 40]}"
    end

    test "state é de uso único, não pode ser inventado nem expirado" do
      resultado = autorizar
      ML::Callback.new(code: "CODE-XYZ", state: resultado[:state], client: @falso).call

      assert_raises(ML::Callback::InvalidState, "replay deveria ser rejeitado") do
        ML::Callback.new(code: "CODE-XYZ", state: resultado[:state], client: @falso).call
      end

      assert_raises(ML::Callback::InvalidState) do
        ML::Callback.new(code: "C", state: "inventado", client: @falso).call
      end

      expirado = autorizar
      OauthState.find_by!(state: expirado[:state]).update_columns(expires_at: 1.minute.ago)

      assert_raises(ML::Callback::InvalidState) do
        ML::Callback.new(code: "C", state: expirado[:state], client: @falso).call
      end
    end

    # ----------------------------------------------------------------- renovação

    test "token válido não é renovado à toa" do
      credencial = conectar
      provider = Credentials::TokenProvider.new(platform_account: credencial.platform_account, client: @falso)

      assert_equal "AT-1", provider.access_token
      assert_empty @falso.refresh_calls
    end

    test "renova antes de expirar e guarda o novo refresh_token" do
      credencial = conectar
      credencial.update_columns(expires_at: 5.minutes.from_now)

      assert credencial.reload.needs_refresh?

      token = Credentials::TokenProvider.new(
        platform_account: credencial.platform_account, client: @falso
      ).access_token

      credencial.reload

      assert_equal credencial.access_token, token
      refute_equal "AT-1", token
      assert_equal "RT-1", @falso.refresh_calls.last, "deve usar o refresh anterior"
      # O refresh do ML é de uso único: perder o novo trava a conta.
      refute_equal "RT-1", credencial.refresh_token
      assert_operator credencial.expires_at, :>, 5.hours.from_now
      assert credencial.last_refreshed_at.present?
    end

    test "recusa na renovação marca a conta para reautorização" do
      credencial = conectar
      credencial.update_columns(expires_at: 1.minute.from_now)

      recusa = Class.new do
        def refresh(refresh_token:)
          raise Marketplace::MercadoLivre::OauthClient::TokenError.new(
            "invalid_grant: expirado", code: "invalid_grant"
          )
        end
      end

      assert_raises(Credentials::TokenProvider::NeedsReauthorization) do
        Credentials::TokenProvider.new(
          platform_account: credencial.platform_account, client: recusa.new
        ).access_token
      end

      credencial.reload

      # O status precisa sobreviver: o erro é levantado, mas antes disso o
      # registro sai da transação gravado como expirado.
      assert_equal "expired", credencial.status
      assert_includes credencial.refresh_error.to_s, "invalid_grant"
      refute Providers::BaseProvider.configured?(credencial.platform_account)
    end

    test "conta sem credencial aponta o caminho para o usuário" do
      conta = criar_conta(tenant: @tenant)

      erro = assert_raises(Credentials::TokenProvider::MissingCredential) do
        Credentials::TokenProvider.new(platform_account: conta).access_token
      end

      assert_includes erro.message, "Integrações"
    end

    # ----------------------------------------------------------------------- job

    test "job renova as credenciais que estão vencendo" do
      credencial = conectar
      credencial.update!(status: :connected, expires_at: 2.minutes.from_now,
                         access_token: "AT-old", refresh_token: "RT-old")

      assert MarketplaceCredential.refreshable.exists?(id: credencial.id)

      # O job constrói o cliente real; trocamos só a chamada de rede.
      resposta = lambda do |refresh_token:|
        { access_token: "AT-job", refresh_token: "RT-job", expires_in: 21_600,
          scope: "read write", user_id: 555_000_111, token_type: "bearer" }
      end

      resumo = com_metodo(ML::OauthClient, :refresh, resposta) { RefreshCredentialsJob.new.perform }

      assert_equal "AT-job", credencial.reload.access_token
      assert_equal 1, resumo[:refreshed]
      assert_equal 0, resumo[:failed]
    end
  end
end
