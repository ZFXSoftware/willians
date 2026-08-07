# Chaves da criptografia de atributos (tokens de marketplace).
#
# Por padrão o Rails lê de credentials, o que exige o master.key e editar um
# arquivo cifrado dentro do container. Aqui damos precedência ao ambiente, que é
# mais prático para deploy em container — se as variáveis não existirem, o Rails
# volta a usar credentials normalmente.
#
# Gere as três chaves com:
#
#   bin/rails db:encryption:init
#
# e copie para o .env como AR_ENCRYPTION_PRIMARY_KEY,
# AR_ENCRYPTION_DETERMINISTIC_KEY e AR_ENCRYPTION_KEY_DERIVATION_SALT.

Rails.application.configure do
  primary = ENV["AR_ENCRYPTION_PRIMARY_KEY"].presence
  deterministic = ENV["AR_ENCRYPTION_DETERMINISTIC_KEY"].presence
  salt = ENV["AR_ENCRYPTION_KEY_DERIVATION_SALT"].presence

  next if primary.blank? || deterministic.blank? || salt.blank?

  config.active_record.encryption.primary_key = primary
  config.active_record.encryption.deterministic_key = deterministic
  config.active_record.encryption.key_derivation_salt = salt
end
