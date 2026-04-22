const express = require('express')
const app = express()

app.use(express.json())

app.post('/api/users', async (req, res) => {
  try {
    const response = await fetch('http://backend:3000/users', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(req.body),
    })

    const text = await response.text()

    // DEBUG (você pode remover depois)
    console.log('STATUS:', response.status)
    console.log('BODY:', text)

    try {
      const data = JSON.parse(text)
      res.status(response.status).json(data)
    } catch (e) {
      res.status(500).json({
        error: 'Resposta não é JSON',
        raw: text
      })
    }

  } catch (err) {
    console.error('ERRO REAL:', err)
    res.status(500).json({ error: 'Erro no gateway' })
  }
})

app.listen(3001, () => {
  console.log('Gateway rodando na porta 3001')
})
