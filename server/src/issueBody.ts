import type { ClassifyResult, NormalizedReport, UploadedFile } from './types.ts'

export function renderIssueBody(input: {
  report: NormalizedReport
  uploadedFiles: UploadedFile[]
  classify?: ClassifyResult
}): string {
  const { report, uploadedFiles, classify = {} } = input
  const lines: string[] = []

  lines.push(`# HollerKit Report ${report.id}`)
  lines.push('')

  if (report.comment) {
    lines.push('## Comment')
    lines.push('')
    lines.push(report.comment)
    lines.push('')
  }

  if (report.transcript) {
    lines.push('## Transcript')
    lines.push('')
    lines.push(report.transcript.text || '_No transcript text available._')
    lines.push('')
    lines.push('| Field | Value |')
    lines.push('| --- | --- |')
    lines.push(`| Locale | ${escapeTable(report.transcript.locale)} |`)
    lines.push(`| Engine | ${escapeTable(report.transcript.engine)} |`)
    if (report.transcript.confidence != null) {
      lines.push(`| Confidence | ${report.transcript.confidence} |`)
    }
    if (report.transcript.durationSeconds != null) {
      lines.push(`| Duration | ${report.transcript.durationSeconds}s |`)
    }
    lines.push('')
  }

  const audio = uploadedFiles.find((file) => file.kind === 'audio')
  if (audio) {
    lines.push('## Audio')
    lines.push('')
    lines.push(`- [${audio.filename}](${audio.url}) (${audio.mimeType}, ${formatBytes(audio.size)})`)
    lines.push('')
  }

  const images = uploadedFiles.filter((file) => file.kind === 'image')
  if (images.length > 0) {
    lines.push('## Images')
    lines.push('')
    for (const image of images) {
      lines.push(`- [${image.filename}](${image.url}) (${image.mimeType}, ${formatBytes(image.size)})`)
    }
    lines.push('')
  }

  lines.push('## Metadata')
  lines.push('')
  lines.push('| Field | Value |')
  lines.push('| --- | --- |')
  lines.push(`| Report ID | ${report.id} |`)
  lines.push(`| Created At | ${report.createdAt} |`)
  lines.push(`| Input Mode | ${report.inputMode} |`)
  if (report.userIdHash) {
    lines.push(`| User ID Hash | ${escapeTable(report.userIdHash)} |`)
  }
  for (const [key, value] of Object.entries(report.metadata)) {
    lines.push(`| ${escapeTable(key)} | ${escapeTable(formatValue(value))} |`)
  }
  lines.push('')

  if (report.breadcrumbs.length > 0) {
    lines.push('## Breadcrumbs')
    lines.push('')
    lines.push('| Time | Category | Message |')
    lines.push('| --- | --- | --- |')
    for (const breadcrumb of report.breadcrumbs) {
      lines.push(
        `| ${escapeTable(breadcrumb.timestamp)} | ${escapeTable(breadcrumb.category ?? '')} | ${escapeTable(breadcrumb.message)} |`,
      )
    }
    lines.push('')
  }

  if (classify.severity || classify.duplicateOf || classify.metadata) {
    lines.push('## Classification')
    lines.push('')
    lines.push('| Field | Value |')
    lines.push('| --- | --- |')
    if (classify.severity) lines.push(`| Severity | ${classify.severity} |`)
    if (classify.duplicateOf) lines.push(`| Duplicate Of | #${classify.duplicateOf} |`)
    if (classify.metadata) lines.push(`| Metadata | ${escapeTable(JSON.stringify(classify.metadata))} |`)
    lines.push('')
  }

  return lines.join('\n')
}

function escapeTable(value: string): string {
  return value.replaceAll('|', '\\|').replaceAll('\n', '<br>')
}

function formatValue(value: unknown): string {
  if (value == null) return ''
  if (typeof value === 'string') return value
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  return JSON.stringify(value)
}

function formatBytes(value: number): string {
  if (value < 1024) return `${value} B`
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`
  return `${(value / 1024 / 1024).toFixed(1)} MB`
}
