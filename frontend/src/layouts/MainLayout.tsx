import { Outlet } from 'react-router-dom'
import Sidebar from '../pages/Parts/Sidebar'
import { useAuth } from '../store/useAuth'

export default function MainLayout() {
  const currentTenantId = useAuth((state) => state.currentTenantId)

  return (
    <div className="min-h-screen bg-zinc-950 text-white flex">
      <Sidebar />

      <main className="flex-1 overflow-auto">
        <div className="p-6 max-w-7xl mx-auto">
          {/* A empresa entra na key para que trocar de empresa REMONTE a tela.
              Sem isso o header X-Tenant-Id muda na próxima requisição, mas o
              que está na tela continua sendo o da empresa anterior — e o
              usuário lê os números de uma como se fossem da outra. */}
          <Outlet key={currentTenantId ?? "sem-empresa"} />
        </div>
      </main>
    </div>
  )
}
