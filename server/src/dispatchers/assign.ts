import type { Dispatcher } from '../types.js'

export type AssignDispatcherOptions = {
  users: string[]
}

export function assign(options: AssignDispatcherOptions): Dispatcher {
  return async (ctx) => {
    if (!ctx.issueAdapter.assign) {
      throw new Error('The configured issue adapter does not support assignment.')
    }

    await ctx.issueAdapter.assign(ctx.issue, options.users)
  }
}
