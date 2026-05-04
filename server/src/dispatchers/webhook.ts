import type { Dispatcher } from '../types.ts'

export type WebhookDispatcherOptions = {
  url: string
  secret?: string
}

export function webhook(options: WebhookDispatcherOptions): Dispatcher {
  return async (ctx) => {
    const body = JSON.stringify({
      report: {
        id: ctx.report.id,
        inputMode: ctx.report.inputMode,
        createdAt: ctx.report.createdAt,
      },
      issue: ctx.issue,
      classify: ctx.classify,
    })

    const headers: Record<string, string> = {
      'content-type': 'application/json',
    }

    if (options.secret) {
      headers['x-hollerkit-webhook-signature'] = await hmacHex(options.secret, body)
    }

    const response = await fetch(options.url, {
      method: 'POST',
      headers,
      body,
    })

    if (!response.ok) {
      throw new Error(`Webhook dispatcher failed with ${response.status}: ${await response.text()}`)
    }
  }
}

async function hmacHex(secret: string, value: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const signature = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(value))
  return Array.from(new Uint8Array(signature), (byte) => byte.toString(16).padStart(2, '0')).join('')
}
