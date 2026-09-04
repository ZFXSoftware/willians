# O certificado A1 da empresa, usado para falar com a SEFAZ.
#
# Guardar isto é diferente de guardar um token de marketplace. Um token dá
# leitura de um extrato; este arquivo É a identidade digital da empresa — quem
# o tem assina documentos como ela perante o fisco. Daí o cuidado extra: o
# conteúdo e a senha ficam cifrados, o arquivo nunca sai por API, e o modelo se
# recusa a guardar o que não conseguir abrir.
class CertificadoDigital < ApplicationRecord
  # O Rails pluraliza em inglês e procuraria `certificado_digitals`. A tabela
  # tem o plural correto em português, como as outras deste projeto.
  self.table_name = "certificados_digitais"

  # Certificado vencido não avisa: a leitura fiscal simplesmente para. Trinta
  # dias é prazo suficiente para renovar sem correria.
  DIAS_DE_AVISO = 30

  belongs_to :tenant

  encrypts :arquivo

  encrypts :senha

  validates :arquivo, :senha, presence: true

  validate :precisa_abrir

  before_validation :ler_do_certificado

  scope :vencendo, -> { where(valido_ate: ..DIAS_DE_AVISO.days.from_now) }

  # O .pfx decodificado, pronto para o TLS mútuo.
  #
  # Reconstruído a cada uso e nunca guardado em memória: o objeto do OpenSSL
  # carrega a chave privada em claro, e mantê-lo vivo num atributo o espalharia
  # por logs de inspeção e dumps de exceção.
  def pkcs12
    OpenSSL::PKCS12.new(Base64.decode64(arquivo.to_s), senha.to_s)
  rescue OpenSSL::PKCS12::PKCS12Error
    nil
  end

  def vencido? = valido_ate.present? && valido_ate < Time.current

  def dias_para_vencer
    return if valido_ate.blank?

    ((valido_ate - Time.current) / 1.day).floor
  end

  # O que a API pode mostrar. NUNCA o arquivo nem a senha — nem truncados: um
  # pedaço de chave privada continua sendo chave privada.
  def resumo
    {
      titular: titular,
      cnpj: cnpj,
      valido_de: valido_de,
      valido_ate: valido_ate,
      dias_para_vencer: dias_para_vencer,
      vencido: vencido?
    }
  end

  private

  # Validade e titular vêm do próprio arquivo, não de campo digitado.
  def ler_do_certificado
    p12 = pkcs12

    return if p12.blank? || p12.certificate.blank?

    cert = p12.certificate

    self.valido_de = cert.not_before
    self.valido_ate = cert.not_after
    self.titular = extrair(cert.subject, "CN")
    self.cnpj = extrair(cert.subject, "CN").to_s[/\d{14}/]
  end

  # Recusar o que não abre é o ponto: certificado com senha errada gravado
  # "com sucesso" só falharia na primeira consulta à SEFAZ, dias depois, longe
  # de quem o cadastrou.
  def precisa_abrir
    return if arquivo.blank? || senha.blank?

    return if pkcs12.present?

    errors.add(:base, "Não consegui abrir o certificado: confira se o arquivo é um .pfx/.p12 válido e se a senha está correta.")
  end

  def extrair(subject, campo)
    subject.to_a.find { |nome, _, _| nome == campo }&.at(1)
  end
end
