# Idempotente: pode rodar quantas vezes quiser.
#
# Cria o mínimo para exercitar o fluxo de conciliação em desenvolvimento —
# um tenant ativo com uma conta de marketplace. Sem credencial configurada, a
# ingestão e o OMIE caem nos providers de simulação.

tenant = Tenant.find_or_create_by!(name: "Tenant Demo") do |t|
  t.document = "00000000000191"
  t.status = :active
end

account = PlatformAccount.find_or_create_by!(
  tenant: tenant,
  platform: "mercado_livre",
  external_id: "demo-ml-001"
) do |a|
  a.name = "Mercado Livre — Loja Demo"
  a.status = :active
end

puts "Tenant ##{tenant.id} — #{tenant.name}"
puts "PlatformAccount ##{account.id} — #{account.platform} (#{account.status})"

# Usuário inicial. Só é criado quando a senha vem do ambiente — nunca há senha
# padrão embutida, para não nascer uma conta previsível em qualquer deploy.
admin_email = ENV["SEED_ADMIN_EMAIL"].presence || "admin@willians.local"
admin_password = ENV["SEED_ADMIN_PASSWORD"].presence

if admin_password.blank?
  puts "SEED_ADMIN_PASSWORD não definido — nenhum usuário criado."
  puts "Defina no .env da raiz e rode de novo, ou cadastre-se por POST /auth/register."
else
  user = User.find_or_initialize_by(email: admin_email.strip.downcase)

  user.name = "Administrador" if user.name.blank?
  user.password = admin_password
  user.status = :active
  user.save!

  TenantUser.find_or_create_by!(tenant: tenant, user: user) do |membership|
    membership.role = :owner
  end

  puts "User ##{user.id} — #{user.email} (owner do tenant ##{tenant.id})"
end
