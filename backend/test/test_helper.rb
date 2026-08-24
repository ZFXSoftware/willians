ENV["RAILS_ENV"] ||= "test"

# Chaves de criptografia PRÓPRIAS do teste, definidas antes de o Rails subir.
#
# Sem isso, qualquer teste que grave um token de marketplace morre com
# "Missing Active Record encryption credential" na máquina de quem não tem as
# variáveis exportadas — e passa na de quem tem. São chaves fixas e públicas de
# propósito: só cifram dados que nascem e morrem dentro da suíte.
{
  "AR_ENCRYPTION_PRIMARY_KEY" => "teste-chave-primaria-nao-use-em-producao",
  "AR_ENCRYPTION_DETERMINISTIC_KEY" => "teste-chave-deterministica-nao-use-em-producao",
  "AR_ENCRYPTION_KEY_DERIVATION_SALT" => "teste-sal-de-derivacao-nao-use-em-producao"
}.each { |chave, valor| ENV[chave] ||= valor }

require_relative "../config/environment"
require "rails/test_help"

Dir[Rails.root.join("test/support/**/*.rb")].each { |f| require f }

# O processo de teste herda o .env, onde estão as credenciais de PRODUÇÃO do
# cliente. Sem limpar, qualquer serviço que monte o cliente real sai para a
# rede — já aconteceu. As que um teste precisar, ele define com `com_env`.
%w[
  OMIE_APP_KEY OMIE_APP_SECRET OMIE_ALLOW_WRITES
  ML_CLIENT_ID ML_CLIENT_SECRET
  SHOPEE_PARTNER_ID SHOPEE_PARTNER_KEY
  AMAZON_CLIENT_ID AMAZON_CLIENT_SECRET AMAZON_APP_ID
  TINY_TOKEN
].each { |chave| ENV.delete(chave) }

module ActiveSupport
  class TestCase
    # Sem paralelismo: vários testes manipulam ENV (credenciais, flags de
    # simulação), e isso não é isolável entre processos.
    #
    # Sem fixtures: o schema mudou muito desde que as geradas foram criadas, e
    # cada teste monta o cenário de que precisa — fica explícito o que está
    # sendo exercitado.
    include Cenario
  end
end
