require "test_helper"

# Guardar um certificado A1 é diferente de guardar um token: este arquivo É a
# identidade digital da empresa. Os testes cobrem o que não pode falhar em
# silêncio — recusar o que não abre, e saber quando vence.
class CertificadoDigitalTest < ActiveSupport::TestCase
  SENHA = "senha-de-teste".freeze

  def setup
    @tenant = criar_tenant
  end

  # Um .pfx de verdade, gerado na hora. Testar com arquivo fixo escondido no
  # repositório seria guardar uma chave privada no git — mesmo de brinquedo, é
  # um hábito que não quero ensinar a este projeto.
  def pfx(cnpj: "12345678000199", validade: 365)
    chave = OpenSSL::PKey::RSA.new(2048)

    cert = OpenSSL::X509::Certificate.new

    cert.version = 2
    cert.serial = 1
    cert.subject = OpenSSL::X509::Name.parse("/CN=EMPRESA TESTE LTDA:#{cnpj}")
    cert.issuer = cert.subject
    cert.public_key = chave.public_key
    cert.not_before = Time.current - 1.day
    cert.not_after = Time.current + validade.days
    cert.sign(chave, OpenSSL::Digest.new("SHA256"))

    Base64.strict_encode64(OpenSSL::PKCS12.create(SENHA, "teste", chave, cert).to_der)
  end

  def criar(arquivo: nil, senha: SENHA, validade: 365)
    CertificadoDigital.create(
      tenant: @tenant, arquivo: arquivo || pfx(validade: validade), senha: senha
    )
  end

  test "lê validade, titular e CNPJ do próprio arquivo" do
    certificado = criar

    assert_predicate certificado, :persisted?
    assert_equal "12345678000199", certificado.cnpj
    assert_match(/EMPRESA TESTE/, certificado.titular)
    assert_operator certificado.valido_ate, :>, Time.current
  end

  # Senha errada gravada "com sucesso" só falharia na primeira consulta à
  # SEFAZ, dias depois, longe de quem cadastrou.
  test "recusa senha errada em vez de guardar" do
    certificado = criar(senha: "errada")

    assert_not certificado.persisted?
    assert_match(/não consegui abrir/i, certificado.errors.full_messages.join)
  end

  test "recusa arquivo que não é um certificado" do
    certificado = criar(arquivo: Base64.strict_encode64("isto não é um pfx"))

    assert_not certificado.persisted?
  end

  # Certificado vencido não avisa sozinho: a leitura fiscal simplesmente para.
  test "sabe quanto falta para vencer e avisa antes" do
    certificado = criar(validade: 10)

    assert_equal 9, certificado.dias_para_vencer
    assert_not certificado.vencido?
    assert_includes CertificadoDigital.vencendo, certificado
  end

  test "certificado longe do vencimento não entra no aviso" do
    assert_empty CertificadoDigital.vencendo.where(id: criar(validade: 200).id)
  end

  # Um pedaço de chave privada continua sendo chave privada.
  test "o resumo para a API não carrega arquivo nem senha" do
    resumo = criar.resumo

    assert_not resumo.key?(:arquivo)
    assert_not resumo.key?(:senha)
    assert_equal "12345678000199", resumo[:cnpj]
  end

  test "uma empresa tem no máximo um certificado" do
    criar

    assert_raises(ActiveRecord::RecordNotUnique) do
      CertificadoDigital.new(tenant: @tenant, arquivo: pfx, senha: SENHA).save(validate: false)
    end
  end
end
