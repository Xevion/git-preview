// Run by `just relative-time-golden` next to the element's dist files.
import { elapsedTime, getRelativeTimeUnit } from './duration.js'
const rtf = new Intl.RelativeTimeFormat('en', { numeric: 'auto', style: 'long' })
function rel(date, now) {
  let d = elapsedTime(date, 'second', now)
  if (d.sign !== -1) return rtf.format(0, 'second')
  const [int, unit] = getRelativeTimeUnit(d, { relativeTo: now })
  if (unit === 'second' && int < 10) return rtf.format(0, 'second')
  return rtf.format(int, unit)
}
// Deterministic LCG so the table is reproducible.
let seed = 12345
const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648
const nows = ['2026-11-17T01:24:00Z','2024-03-01T05:00:00Z','2025-01-31T23:30:00Z','2026-03-08T09:00:00Z','2025-12-31T12:00:00Z','2024-02-29T18:00:00Z','2026-05-31T03:00:00Z','2026-07-15T14:00:00Z']
const spans = [60, 3600, 86400, 7*86400, 40*86400, 400*86400, 3000*86400]
const out = []
for (const n of nows) {
  const now = Date.parse(n) / 1000
  for (const span of spans) for (let i = 0; i < 12; i++) {
    const ago = Math.floor(rnd() * span)
    out.push(`${now - ago} ${now} ${rel(new Date((now - ago) * 1000), now * 1000)}`)
  }
}
console.log(out.join('\n'))
