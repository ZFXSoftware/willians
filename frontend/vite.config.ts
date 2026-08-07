import { defineConfig } from 'vite'
import react, { reactCompilerPreset } from '@vitejs/plugin-react'
import babel from '@rolldown/plugin-babel'

// Hosts liberados para o dev server. O Vite bloqueia Host desconhecido, então o
// domínio do túnel (ngrok/Cloudflare) precisa entrar aqui via PUBLIC_HOST.
const allowedHosts = [
  'dev.conciliation.zfxsoftware.cloud',
  process.env.VITE_ALLOWED_HOST,
].filter(Boolean) as string[]

// https://vite.dev/config/
export default defineConfig({
  plugins: [
    react(),
    babel({ presets: [reactCompilerPreset()] })
  ],

  server: {
    host: "0.0.0.0",

    allowedHosts,

    hmr: {
      // O TLS termina no túnel; o browser conecta o websocket na 443.
      clientPort: 443
    }
  }
})
