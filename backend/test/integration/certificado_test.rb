require "test_helper"

# O upload é a porta de entrada da identidade digital da empresa. O que se
# testa aqui é sobretudo o que NÃO pode acontecer.
class CertificadoControllerTest < ActionDispatch::IntegrationTest
  SENHA = "senha-de-teste".freeze

  SENHA_DO_USUARIO = "senha-longa-de-teste".freeze

  def setup
    @tenant = criar_tenant
    @dono = criar_usuario(tenant: @tenant, papel: :owner)
    @dono.update!(password: SENHA_DO_USUARIO)

    post "/auth/login", params: { email: @dono.email, password: SENHA_DO_USUARIO }, as: :json

    @headers = {
      "Authorization" => "Bearer #{response.parsed_body['token']}",
      "X-Tenant-Id" => @tenant.id.to_s
    }
  end

  def pfx_bruto(validade: 365)
    chave = OpenSSL::PKey::RSA.new(2048)

    cert = OpenSSL::X509::Certificate.new

    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse("/CN=EMPRESA TESTE LTDA:12345678000199")
    cert.issuer = cert.subject
    cert.public_key = chave.public_key
    cert.not_before = Time.current - 1.day
    cert.not_after = Time.current + validade.days
    cert.sign(chave, OpenSSL::Digest.new("SHA256"))

    OpenSSL::PKCS12.create(SENHA, "teste", chave, cert).to_der
  end

  def enviar(conteudo: nil, senha: SENHA, validade: 365)
    arquivo = Tempfile.new([ "cert", ".pfx" ], binmode: true)

    arquivo.write(conteudo || pfx_bruto(validade: validade))

    arquivo.rewind

    post "/integracoes/certificado",
         params: { arquivo: Rack::Test::UploadedFile.new(arquivo.path, "application/x-pkcs12"), senha: senha },
         headers: @headers
  end

  test "aceita o certificado e devolve o resumo" do
    enviar

    assert_response :success

    corpo = JSON.parse(response.body)

    assert corpo["configurado"]
    assert_equal "12345678000199", corpo.dig("certificado", "cnpj")
  end

  # Um pedaço de chave privada continua sendo chave privada.
  test "a resposta nunca carrega o arquivo nem a senha" do
    enviar

    assert_not_includes response.body, "senha-de-teste"
    assert_not_includes response.body.downcase, "arquivo"
  end

  test "senha errada é recusada na hora, não guardada" do
    enviar(senha: "errada")

    assert_response :unprocessable_content
    assert_equal 0, CertificadoDigital.count
  end

  test "arquivo que não é certificado é recusado" do
    enviar(conteudo: "isto não é um pfx")

    assert_response :unprocessable_content
  end

  # Certificado vencido para a leitura fiscal em silêncio. O aviso é a única
  # coisa que impede isso.
  test "avisa quando o vencimento está próximo" do
    enviar(validade: 10)

    assert_match(/vence em/i, JSON.parse(response.body)["aviso"].to_s)
  end

  test "sem vencimento próximo não há aviso" do
    enviar(validade: 200)

    assert_nil JSON.parse(response.body)["aviso"]
  end

  test "subir de novo substitui, não acumula" do
    enviar
    enviar

    assert_equal 1, CertificadoDigital.where(tenant: @tenant).count
  end

  test "dá para remover" do
    enviar

    delete "/integracoes/certificado", headers: @headers

    assert_response :success
    assert_not JSON.parse(response.body)["configurado"]
  end

  test "sem sessão não entra nada" do
    post "/integracoes/certificado", params: { senha: SENHA }

    assert_response :unauthorized
  end
end
