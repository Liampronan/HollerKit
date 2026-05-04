import type { Dispatcher, NormalizedReport } from '../types.ts'

export type CommentDispatcherOptions = {
  template: (report: NormalizedReport) => string
}

export function comment(options: CommentDispatcherOptions): Dispatcher {
  return async (ctx) => {
    if (!ctx.issueAdapter.commentIssue) {
      throw new Error('The configured issue adapter does not support issue comments.')
    }

    await ctx.issueAdapter.commentIssue(ctx.issue, options.template(ctx.report))
  }
}
