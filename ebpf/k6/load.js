import http from 'k6/http'
import { sleep, check } from 'k6'

const BASE = __ENV.BASE_URL || 'http://localhost:3000'

export default function () {
  const health = http.get(`${BASE}/health`)
  check(health, { 'health 200': (r) => r.status === 200 })

  const list = http.get(`${BASE}/api/v1/products`)
  check(list, { 'list 200': (r) => r.status === 200 })

  const created = http.post(
    `${BASE}/api/v1/products`,
    JSON.stringify({ name: `k6-${Date.now()}`, price: 9.99 }),
    { headers: { 'Content-Type': 'application/json' } }
  )
  if (created.status === 201 || created.status === 200) {
    const id = created.json('data.id')
    if (id) http.get(`${BASE}/api/v1/products/${id}`)
  }

  sleep(1)
}
