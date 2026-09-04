class CriarCertificadosDigitais < ActiveRecord::Migration[8.1]
  def change
    create_table :certificados_digitais do |t|
      t.references :tenant, null: false, foreign_key: true

      # O .pfx inteiro, em base64 e cifrado pelo Active Record Encryption.
      #
      # Um certificado A1 não é uma chave de API: é a identidade digital da
      # empresa, e quem o tem assina documentos como ela. Guardar em texto no
      # banco seria inaceitável — cifrado, o dump do banco sozinho não basta.
      t.text :arquivo, null: false

      t.text :senha, null: false

      # Lidos do próprio certificado na hora do upload, não digitados.
      #
      # Digitar validade e CNPJ à mão convida ao erro que este sistema não
      # perdoa: um certificado vencido para de funcionar em silêncio, e um CNPJ
      # errado só aparece quando a SEFAZ recusa.
      t.string :titular
      t.string :cnpj
      t.datetime :valido_de
      t.datetime :valido_ate

      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    # Um certificado por empresa. Duas identidades digitais para o mesmo CNPJ
    # seria ambiguidade sobre qual assina.
    add_index :certificados_digitais, :tenant_id, unique: true, name: "idx_certificado_por_empresa"

    add_index :certificados_digitais, :valido_ate
  end
end
