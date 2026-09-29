import { FileCheck2 } from "lucide-react"

export default function ConciliaNota() {
  return (
    <div className="space-y-6">
      <div>
        <p className="text-zinc-400 text-sm">Conciliação Financeira</p>
        <h1 className="text-3xl font-bold tracking-tight mt-1 text-zinc-100">ConciliaNota</h1>
      </div>

      <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-12 shadow-xl flex flex-col items-center text-center">
        <div className="w-14 h-14 rounded-2xl bg-white/5 border border-white/10 flex items-center justify-center text-zinc-400">
          <FileCheck2 size={24} />
        </div>

        <h2 className="text-xl font-semibold mt-5 text-zinc-100">Em breve</h2>

        <p className="text-sm text-zinc-400 mt-3 max-w-md">
          Esta tela está em desenvolvimento.
        </p>
      </div>
    </div>
  )
}
