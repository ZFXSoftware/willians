import { useEffect, useState } from "react"
import { Link } from "react-router-dom"
import {
  Check,
  Copy,
  ExternalLink,
  Eye,
  EyeOff,
  KeyRound,
  RefreshCw,
  ShieldCheck,
  Store,
  Trash2,
} from "lucide-react"

import {
  apagarConfiguracao,
  fetchCanais,
  fetchConfiguracoes,
  mapearCanal,
  salvarConfiguracao,
  type CampoConfiguracao,
  type ProvedorConfiguracao,
} from "../../api/configuracoes"
import { errorMessage } from "../../api/client"
import { useResource } from "../../hooks/useResource"
import { Carregando, ErroAoCarregar } from "../../components/Estados"
import { EscolhaDoOmie } from "../../components/EscolhaDoOmie"

const ORIGENS: Record<string, { texto: string; classe: string }> = {
  configuracao: {
    texto: "Definido aqui",
    classe: "bg-emerald-500/15 text-emerald-400 border-emerald-500/20",
  },
  ambiente: {
    texto: "Vem do servidor",
    classe: "bg-sky-500/15 text-sky-400 border-sky-500/20",
  },
  padrao: {
    texto: "Padrão",
    classe: "bg-zinc-500/15 text-zinc-300 border-zinc-500/20",
  },
  faltando: {
    texto: "Faltando",
    classe: "bg-red-500/15 text-red-400 border-red-500/20",
  },
}

// Campo vazio que NÃO é obrigatório não está faltando — só não foi
// preenchido. Marcar os cinco códigos do plano de contas do OMIE com um selo
// vermelho de "Faltando" dizia que a integração estava quebrada quando ela
// estava funcionando: eles só fazem falta na hora de GRAVAR no ERP, e a
// leitura (que é o que a conciliação faz) não usa nenhum deles.
const OPCIONAL_VAZIO = {
  texto: "Só para gravar",
  classe: "bg-zinc-500/15 text-zinc-400 border-zinc-500/20",
}

export default function Settings() {
  const { data, loading, error, reload } = useResource(fetchConfiguracoes)

  return (
    <div className="space-y-6">
      <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
        <div>
          <p className="text-zinc-400 text-sm">Conciliação Financeira</p>
          <h1 className="text-3xl font-bold tracking-tight mt-1">
            Configurações das integrações
          </h1>
          <p className="text-sm text-zinc-400 mt-2 max-w-2xl">
            As chaves ficam guardadas cifradas e valem só para esta empresa.
            Depois de preencher, a conexão de cada conta é feita na tela de
            Integrações.
          </p>
        </div>

        <button
          onClick={reload}
          className="flex items-center gap-2 bg-zinc-900 border border-zinc-800 hover:border-zinc-600 px-4 py-3 rounded-xl text-sm transition shrink-0"
        >
          <RefreshCw size={15} />
          Atualizar
        </button>
      </div>

      {loading ? (
        <Carregando />
      ) : error ? (
        <ErroAoCarregar mensagem={error} onRetry={reload} />
      ) : (
        <div className="space-y-4">
          <CartaoCanais />

          {data?.provedores.map((provedor) => (
            <CartaoProvedor
              key={provedor.chave}
              provedor={provedor}
              urlDeRetorno={data.urls_de_retorno[provedor.chave] ?? null}
            />
          ))}
        </div>
      )}
    </div>
  )
}

// De qual canal veio cada nota.
//
// A NF-e diz quem intermediou a venda, mas o nome é o que o cliente escolheu
// usar: além dos marketplaces, apareceu "Alma teen" — venda de balcão emitida
// como digital por exigência fiscal, que não é marketplace nenhum e não tem
// repasse de ninguém. Nenhum código adivinha isso.
//
// Enquanto um nome estiver sem canal, as notas dele não viram pedido. Por isso
// os pendentes vêm primeiro e com aviso: é trabalho, não detalhe.
function CartaoCanais() {
  const { data, loading, error, reload } = useResource(fetchCanais)
  const [salvando, setSalvando] = useState<string | null>(null)
  const [aviso, setAviso] = useState<string | null>(null)

  async function escolher(nome: string, canal: string) {
    setSalvando(nome)
    setAviso(null)

    try {
      await mapearCanal(nome, canal)
      reload()
    } catch (e) {
      setAviso(errorMessage(e, "Não foi possível gravar o canal"))
    } finally {
      setSalvando(null)
    }
  }

  if (loading || error || !data || (data.items.length === 0 && data.aguardando_leitura === 0)) {
    return null
  }

  return (
    <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-6 shadow-xl">
      <div className="flex items-center gap-4">
        <div className="w-12 h-12 rounded-2xl bg-white/5 border border-white/10 flex items-center justify-center text-zinc-300 shrink-0">
          <Store size={20} />
        </div>

        <div className="min-w-0">
          <h2 className="font-semibold text-lg">Canais de venda</h2>
          <p className="text-sm text-zinc-400 mt-0.5 max-w-xl">
            A nota fiscal diz quem intermediou a venda. O que cada nome
            significa só você sabe — e é isso que decide em qual conciliação a
            venda entra.
          </p>
        </div>
      </div>

      {data.sem_canal > 0 && (
        <p className="mt-4 text-sm text-amber-300 bg-amber-500/10 border border-amber-500/20 rounded-xl px-4 py-3">
          {data.sem_canal} nome(s) sem canal. As notas deles não viram pedido e
          ficam fora de qualquer conciliação até alguém dizer o que são.
        </p>
      )}

      {data.aguardando_leitura > 0 && (
        <p className="mt-4 text-sm text-sky-300 bg-sky-500/10 border border-sky-500/20 rounded-xl px-4 py-3">
          {data.aguardando_leitura} nota(s) ainda não foram lidas. O sistema lê
          em lotes, sozinho — esta lista cresce nas próximas horas.
        </p>
      )}

      {aviso && <p className="mt-4 text-sm text-red-400">{aviso}</p>}

      <div className="mt-5 space-y-2">
        {data.items.map((item) => (
          <div
            key={item.nome}
            className="flex flex-wrap items-center justify-between gap-3 border border-zinc-800 rounded-xl px-4 py-3"
          >
            <div className="min-w-0">
              <p className="text-sm font-medium">{item.nome}</p>
              <p className="text-xs text-zinc-500 mt-0.5">
                {item.cnpj ?? "sem CNPJ"} · {item.notas} nota(s)
              </p>
            </div>

            <select
              value={item.canal ?? ""}
              disabled={salvando === item.nome}
              onChange={(e) => escolher(item.nome, e.target.value)}
              className={`bg-zinc-950 border rounded-xl px-3 py-2 text-sm outline-none focus:border-zinc-600 disabled:opacity-50 ${
                item.canal ? "border-zinc-800" : "border-amber-500/40"
              }`}
            >
              <option value="">Escolha o canal...</option>
              {data.opcoes.map((o) => (
                <option key={o.canal} value={o.canal}>
                  {o.rotulo}
                </option>
              ))}
            </select>
          </div>
        ))}
      </div>
    </div>
  )
}

function CartaoProvedor({
  provedor: inicial,
  urlDeRetorno,
}: {
  provedor: ProvedorConfiguracao
  urlDeRetorno: string | null
}) {
  const [provedor, setProvedor] = useState(inicial)
  const [rascunho, setRascunho] = useState<Record<string, string>>({})
  const [salvando, setSalvando] = useState(false)
  const [aviso, setAviso] = useState<string | null>(null)
  const [sucesso, setSucesso] = useState(false)

  useEffect(() => setProvedor(inicial), [inicial])

  const alterado = Object.keys(rascunho).length > 0

  function editar(chave: string, valor: string) {
    setSucesso(false)
    setRascunho((atual) => ({ ...atual, [chave]: valor }))
  }

  async function salvar() {
    setSalvando(true)
    setAviso(null)

    try {
      setProvedor(await salvarConfiguracao(provedor.chave, rascunho))
      setRascunho({})
      setSucesso(true)
    } catch (e) {
      setAviso(errorMessage(e, "Não foi possível salvar"))
    } finally {
      setSalvando(false)
    }
  }

  async function apagar(chave: string) {
    setSalvando(true)
    setAviso(null)

    try {
      setProvedor(await apagarConfiguracao(provedor.chave, chave))
      setRascunho(({ [chave]: _, ...resto }) => resto)
    } catch (e) {
      setAviso(errorMessage(e, "Não foi possível apagar"))
    } finally {
      setSalvando(false)
    }
  }

  return (
    <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-6 shadow-xl">
      <div className="flex items-start justify-between gap-4 flex-wrap">
        <div className="flex items-center gap-4 min-w-0">
          <div className="w-12 h-12 rounded-2xl bg-white/5 border border-white/10 flex items-center justify-center text-zinc-300 shrink-0">
            <KeyRound size={20} />
          </div>

          <div className="min-w-0">
            <h2 className="font-semibold text-lg">{provedor.rotulo}</h2>
            <p className="text-sm text-zinc-400 mt-0.5 max-w-xl">{provedor.ajuda}</p>
          </div>
        </div>

        <span
          className={`inline-flex items-center gap-1.5 px-3 py-1 rounded-full text-xs font-medium border ${
            provedor.configurado
              ? "bg-emerald-500/15 text-emerald-400 border-emerald-500/20"
              : "bg-yellow-500/15 text-yellow-400 border-yellow-500/20"
          }`}
        >
          {provedor.configurado ? <ShieldCheck size={13} /> : null}
          {provedor.configurado
            ? "Configurado"
            : `Falta: ${provedor.pendencias.join(", ")}`}
        </span>
      </div>

      <div className="mt-6 border-t border-zinc-800 pt-6 grid grid-cols-1 lg:grid-cols-2 gap-5">
        {provedor.campos.map((campo) => (
          <Campo
            key={campo.chave}
            campo={campo}
            rascunho={rascunho[campo.chave]}
            onChange={(valor) => editar(campo.chave, valor)}
            onApagar={() => apagar(campo.chave)}
            desabilitado={salvando}
          />
        ))}
      </div>

      {urlDeRetorno && <UrlDeRetorno url={urlDeRetorno} />}

      {aviso && (
        <p className="mt-5 bg-red-500/10 border border-red-500/20 rounded-2xl px-4 py-3 text-sm text-red-300">
          {aviso}
        </p>
      )}

      <div className="mt-6 flex items-center gap-3">
        <button
          onClick={salvar}
          disabled={!alterado || salvando}
          className="bg-emerald-600 hover:bg-emerald-500 disabled:opacity-40 disabled:hover:bg-emerald-600 transition px-5 py-2.5 rounded-xl text-sm font-medium"
        >
          {salvando ? "Salvando..." : "Salvar"}
        </button>

        {alterado && !salvando && (
          <button
            onClick={() => setRascunho({})}
            className="text-sm text-zinc-400 hover:text-white transition"
          >
            Descartar
          </button>
        )}

        {sucesso && !alterado && (
          <span className="inline-flex items-center gap-1.5 text-sm text-emerald-400">
            <Check size={15} />
            Salvo
          </span>
        )}

        <a
          href={provedor.documentacao}
          target="_blank"
          rel="noreferrer"
          className="ml-auto inline-flex items-center gap-1.5 text-sm text-zinc-400 hover:text-white transition"
        >
          Onde conseguir
          <ExternalLink size={14} />
        </a>
      </div>
    </div>
  )
}

function Campo({
  campo,
  rascunho,
  onChange,
  onApagar,
  desabilitado,
}: {
  campo: CampoConfiguracao
  rascunho: string | undefined
  onChange: (valor: string) => void
  onApagar: () => void
  desabilitado: boolean
}) {
  const [visivel, setVisivel] = useState(false)

  const origem =
    campo.origem === "faltando" && !campo.obrigatorio
      ? OPCIONAL_VAZIO
      : ORIGENS[campo.origem] ?? ORIGENS.faltando

  // Segredo já gravado não volta do servidor: o campo fica vazio, e a pista
  // (últimos caracteres) mostra que existe algo lá.
  const valor = rascunho ?? (campo.secreto ? "" : campo.valor ?? "")

  return (
    <div>
      <div className="flex items-center justify-between gap-3">
        <label className="text-sm font-medium">
          {campo.rotulo}
          {campo.obrigatorio && <span className="text-red-400 ml-1">*</span>}
        </label>

        <span className={`px-2.5 py-0.5 rounded-full text-[11px] border ${origem.classe}`}>
          {origem.texto}
        </span>
      </div>

      <div className="mt-2 flex items-center gap-2">
        {campo.tipo === "booleano" ? (
          <select
            value={valor === "true" ? "true" : "false"}
            onChange={(e) => onChange(e.target.value)}
            disabled={desabilitado}
            className="flex-1 bg-zinc-950 border border-zinc-800 focus:border-zinc-600 outline-none rounded-xl px-4 py-2.5 text-sm transition"
          >
            <option value="false">Não</option>
            <option value="true">Sim</option>
          </select>
        ) : campo.tipo === "data" ? (
          <input
            type="date"
            value={valor}
            onChange={(e) => onChange(e.target.value)}
            disabled={desabilitado}
            className="flex-1 bg-zinc-950 border border-zinc-800 focus:border-zinc-600 outline-none rounded-xl px-4 py-2.5 text-sm transition"
          />
        ) : campo.tipo === "opcao" ? (
          <select
            value={valor}
            onChange={(e) => onChange(e.target.value)}
            disabled={desabilitado}
            className="flex-1 bg-zinc-950 border border-zinc-800 focus:border-zinc-600 outline-none rounded-xl px-4 py-2.5 text-sm transition"
          >
            {campo.opcoes?.map((opcao) => (
              <option key={opcao.valor} value={opcao.valor}>
                {opcao.rotulo}
              </option>
            ))}
          </select>
        ) : campo.fonte ? (
          /* O código vem de um cadastro do OMIE: procura pelo NOME em vez de
             exigir que a pessoa cole um número copiado de um terminal. */
          <div className="flex-1">
            <EscolhaDoOmie tipo={campo.fonte} valor={valor} aoEscolher={onChange} />
          </div>
        ) : (
          <input
            type={campo.secreto && !visivel ? "password" : "text"}
            value={valor}
            onChange={(e) => onChange(e.target.value)}
            disabled={desabilitado}
            placeholder={campo.secreto && campo.preenchido ? campo.pista ?? "" : ""}
            autoComplete="off"
            spellCheck={false}
            className="flex-1 bg-zinc-950 border border-zinc-800 focus:border-zinc-600 outline-none rounded-xl px-4 py-2.5 text-sm font-mono transition"
          />
        )}

        {campo.secreto && (
          <button
            type="button"
            onClick={() => setVisivel((v) => !v)}
            title={visivel ? "Ocultar" : "Mostrar o que estou digitando"}
            className="p-2.5 rounded-xl border border-zinc-800 text-zinc-400 hover:text-white hover:border-zinc-600 transition"
          >
            {visivel ? <EyeOff size={15} /> : <Eye size={15} />}
          </button>
        )}

        {campo.origem === "configuracao" && (
          <button
            type="button"
            onClick={onApagar}
            disabled={desabilitado}
            title="Apagar e voltar ao valor do servidor"
            className="p-2.5 rounded-xl border border-zinc-800 text-zinc-400 hover:text-red-400 hover:border-red-500/30 transition"
          >
            <Trash2 size={15} />
          </button>
        )}
      </div>

      {campo.ajuda && <p className="text-xs text-zinc-500 mt-2">{campo.ajuda}</p>}

      {/* A dúvida nasce AQUI: um campo só, e vários marketplaces para atender.
          A resposta — que cada conta tem o seu — estava na outra tela, e quem
          não sabe que ela existe não vai procurar. A placa fica onde a pessoa
          está olhando. */}
      {campo.por_conta && (
        <p className="text-xs text-sky-300/80 mt-1">
          Vale para todos os marketplaces. Se cada um tem o seu no OMIE,
          preencha por conta em{" "}
          <Link to="/integracoes" className="underline hover:text-sky-200">
            Integrações
          </Link>{" "}
          — ali cada conta tem este campo, e o que estiver em branco usa o valor
          desta tela.
        </p>
      )}

      {campo.origem === "ambiente" && (
        <p className="text-xs text-zinc-500 mt-1">
          Hoje vem de <code className="text-zinc-400">{campo.variavel_de_ambiente}</code>.
          Preencher aqui passa a valer no lugar.
        </p>
      )}
    </div>
  )
}

function UrlDeRetorno({ url }: { url: string }) {
  const [copiado, setCopiado] = useState(false)

  async function copiar() {
    await navigator.clipboard.writeText(url)
    setCopiado(true)
    setTimeout(() => setCopiado(false), 2000)
  }

  return (
    <div className="mt-6 bg-zinc-950 border border-zinc-800 rounded-2xl px-4 py-3">
      <p className="text-xs text-zinc-400">
        Cadastre esta URL de retorno no portal da plataforma — ela precisa ser
        idêntica, caractere por caractere.
      </p>

      <div className="mt-2 flex items-center gap-2">
        <code className="flex-1 text-xs text-zinc-300 font-mono truncate">{url}</code>

        <button
          onClick={copiar}
          className="inline-flex items-center gap-1.5 text-xs text-zinc-400 hover:text-white transition shrink-0"
        >
          {copiado ? <Check size={13} /> : <Copy size={13} />}
          {copiado ? "Copiado" : "Copiar"}
        </button>
      </div>
    </div>
  )
}
