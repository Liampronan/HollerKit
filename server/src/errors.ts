export class HollerKitError extends Error {
  readonly status: number
  readonly code: string

  constructor(status: number, code: string, message: string) {
    super(message)
    this.name = 'HollerKitError'
    this.status = status
    this.code = code
  }
}

export function errorResponse(error: unknown): Response {
  if (error instanceof HollerKitError) {
    return Response.json(
      { ok: false, error: { code: error.code, message: error.message } },
      { status: error.status },
    )
  }

  return Response.json(
    { ok: false, error: { code: 'internal_error', message: 'Unexpected server error.' } },
    { status: 500 },
  )
}
