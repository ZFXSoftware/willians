FROM ruby:3.2

WORKDIR /app

RUN apt-get update -qq && apt-get install -y \
  build-essential \
  libpq-dev \
  nodejs \
  && rm -rf /var/lib/apt/lists/*

RUN gem install bundler rails

COPY . .

# O `|| true` original transformava falha de rede em imagem sem gems, com build
# saindo 0 — o erro só aparecia no boot do Rails. Agora a falha é visível, e as
# gems ficam no volume `bundle_cache` (ver docker-compose), então basta rodar
# `docker compose run --rm backend bundle install` para consertar sem rebuild.
RUN bundle install || echo ">>> AVISO: bundle install FALHOU no build. Rode: docker compose run --rm --user root backend bundle install"

EXPOSE 3000

CMD ["bash", "-c", "rm -f tmp/pids/server.pid && bundle exec rails s -b 0.0.0.0"]
