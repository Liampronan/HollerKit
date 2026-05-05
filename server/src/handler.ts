import { errorResponse, HollerKitError } from './errors.js'
import { verifyHmac } from './hmac.js'
import { renderIssueBody } from './issueBody.js'
import { resolveLimits, validateContentLength, validateReportLimits, validateTimestamp } from './limits.js'
import { normalizeReport } from './normalize.js'
import type {
  ClassifyResult,
  CreateBugReportHandlerOptions,
  DispatchWhen,
  IssueResult,
  UploadedFile,
} from './types.js'

export function createBugReportHandler(options: CreateBugReportHandlerOptions): (request: Request) => Promise<Response> {
  const limits = resolveLimits(options.limits)
  const now = options.now ?? (() => new Date())
  const idGenerator = options.idGenerator ?? defaultId

  return async function hollerKitHandler(request: Request): Promise<Response> {
    try {
      if (request.method !== 'POST') {
        throw new HollerKitError(405, 'method_not_allowed', 'HollerKit only accepts POST requests.')
      }

      validateContentLength(request.headers.get('content-length'), limits)
      const verified = await verifyHmac(request, options.appSecret, limits.maxBodyBytes)
      validateTimestamp(verified.timestamp, now(), limits)

      const report = await normalizeReport({
        request,
        body: verified.body,
        now: now(),
        id: idGenerator(),
      })
      validateReportLimits(report, limits)

      const classify: ClassifyResult = options.classify ? await options.classify(report) : {}
      const uploadedFiles = await uploadFiles(options.storage, report.id, [
        ...report.files.images,
        ...(report.files.audio ? [report.files.audio] : []),
      ])

      if (classify.skip) {
        await options.onReport?.({ report, uploadedFiles, classify, skipped: true })
        return Response.json({ ok: true, reportId: report.id, skipped: true })
      }

      const issue = await createIssue(options, report, uploadedFiles, classify)
      await maybeDispatch(options, { report, issue, issueAdapter: options.issue, uploadedFiles, classify })
      await options.onReport?.({ report, issue, uploadedFiles, classify, skipped: false })

      return Response.json({ ok: true, issueUrl: issue.url, reportId: report.id })
    } catch (error) {
      return errorResponse(error)
    }
  }
}

async function uploadFiles(
  storage: CreateBugReportHandlerOptions['storage'],
  reportId: string,
  files: Parameters<NonNullable<CreateBugReportHandlerOptions['storage']>['upload']>[1],
): Promise<UploadedFile[]> {
  if (files.length === 0) return []
  if (!storage) {
    throw new HollerKitError(500, 'missing_storage_adapter', 'A storage adapter is required when reports include files.')
  }

  return storage.upload(reportId, files)
}

async function createIssue(
  options: CreateBugReportHandlerOptions,
  report: Parameters<CreateBugReportHandlerOptions['issue']['createIssue']>[0]['report'],
  uploadedFiles: UploadedFile[],
  classify: ClassifyResult,
): Promise<IssueResult> {
  const body = renderIssueBody({ report, uploadedFiles, classify })
  return options.issue.createIssue({ report, uploadedFiles, classify, body })
}

async function maybeDispatch(
  options: CreateBugReportHandlerOptions,
  ctx: {
    report: Parameters<CreateBugReportHandlerOptions['issue']['createIssue']>[0]['report']
    issue: IssueResult
    issueAdapter: CreateBugReportHandlerOptions['issue']
    uploadedFiles: UploadedFile[]
    classify: ClassifyResult
  },
): Promise<void> {
  if (!options.dispatch || !shouldDispatch(options.dispatch.when, ctx.report)) return

  const handlers = Array.isArray(options.dispatch.handler)
    ? options.dispatch.handler
    : [options.dispatch.handler]

  for (const handler of handlers) {
    await handler(ctx)
  }
}

function shouldDispatch(when: DispatchWhen, report: Parameters<CreateBugReportHandlerOptions['issue']['createIssue']>[0]['report']): boolean {
  if (when === 'always') return true
  if (typeof when === 'function') return when(report)
  return when.allowlist.includes(report.inputMode)
}

function defaultId(): string {
  return crypto.randomUUID()
}
