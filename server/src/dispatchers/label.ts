import type { Dispatcher } from '../types.ts'

export type LabelDispatcherOptions = {
  name: string
}

export function label(options: LabelDispatcherOptions): Dispatcher {
  return async (ctx) => {
    if (!ctx.issueAdapter.addLabels) {
      throw new Error('The configured issue adapter does not support labels.')
    }

    await ctx.issueAdapter.addLabels(ctx.issue, [options.name])
  }
}
