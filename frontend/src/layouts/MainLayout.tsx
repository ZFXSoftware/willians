import { Outlet } from 'react-router-dom'
import Sidebar from '../pages/Parts/Sidebar'

export default function MainLayout() {
  return (
    <div className="min-h-screen bg-zinc-950 text-white flex">
      <Sidebar />

      <main className="flex-1 overflow-auto">
        <div className="p-6 max-w-7xl mx-auto">
          <Outlet />
        </div>
      </main>
    </div>
  )
}
