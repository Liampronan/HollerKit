import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { resolveV1Limits, type V1LimitConfig } from './server.js'
import { computeQuestContentHash, type QuestDefinitionInput } from './store.js'

export interface ConformanceSuiteOptions {
  baseUrl?: string | undefined
  fetch?: typeof globalThis.fetch | undefined
  handler?: ((request: Request) => Promise<Response>) | undefined
  testerToken: string
  otherTesterToken?: string | undefined
  questsWriteKey: string
  agentKey: string
  limits?: Partial<V1LimitConfig> | undefined
}

export interface ConformanceStepResult {
  name: string
  durationMs: number
}

export interface ConformanceResult {
  ok: true
  steps: ConformanceStepResult[]
}

export async function runConformanceSuite(
  options: ConformanceSuiteOptions,
): Promise<ConformanceResult> {
  const baseUrl = (options.baseUrl ?? 'http://hollerkit.local').replace(/\/$/, '')
  const limits = resolveV1Limits(options.limits)
  const fetchFn: typeof globalThis.fetch =
    options.fetch ??
    (options.handler
      ? async (input, init) => options.handler!(new Request(input, init))
      : globalThis.fetch)

  const steps: ConformanceStepResult[] = []

  async function step(name: string, fn: () => Promise<void>): Promise<void> {
    const start = performance.now()
    await fn()
    steps.push({ name, durationMs: Math.round(performance.now() - start) })
  }

  async function requestJson(
    path: string,
    init: {
      method?: string
      token?: string | null
      headers?: Record<string, string>
      body?: unknown
      rawBody?: string
    } = {},
  ): Promise<{ status: number; headers: Headers; body: any }> {
    const headers: Record<string, string> = {
      ...(init.headers ?? {}),
    }
    if (init.token) {
      headers['authorization'] = `Bearer ${init.token}`
    }
    let payload: string | undefined
    if (init.rawBody !== undefined) {
      payload = init.rawBody
      headers['content-type'] = headers['content-type'] ?? 'application/json'
    } else if (init.body !== undefined) {
      payload = JSON.stringify(init.body)
      headers['content-type'] = headers['content-type'] ?? 'application/json'
    }

    const requestInit: RequestInit = {
      method: init.method ?? 'GET',
      headers,
    }
    if (payload !== undefined) {
      requestInit.body = payload
    }

    const response = await fetchFn(`${baseUrl}${path}`, requestInit)
    const json = await response.json()
    return { status: response.status, headers: response.headers, body: json }
  }

  const questAlphaV1: QuestDefinitionInput = {
    id: 'feed-detail-zoom',
    title: 'Open a feed card and come back',
    area: 'feed',
    source: { pr: 55, added: '2026-11-07' },
    setup: ['Settings -> Experiments -> Feed on'],
    steps: ['Scroll to the third card', 'Tap it; the zoom transition plays', 'Go back'],
    expect: ['Back returns to the same card at the same scroll position'],
    needs: ['device', 'backend'],
    record: 'suggested',
    start: 'trashapp://feed',
  }

  const questBetaV1: QuestDefinitionInput = {
    id: 'profile-avatar-crop',
    title: 'Crop a new avatar photo',
    area: 'profile',
    source: { pr: 56, added: '2026-11-07' },
    steps: ['Open Profile', 'Tap avatar', 'Pinch to zoom and save'],
    expect: ['Updated avatar persists after reload'],
  }

  // 1. Protocol header check
  await step('protocol header on responses and 400 on unsupported protocol version', async () => {
    const badProto = await requestJson('/v1/quests', {
      method: 'GET',
      token: options.agentKey,
      headers: { 'hollerkit-protocol': '2' },
    })
    assert.equal(badProto.status, 400)
    assert.equal(badProto.headers.get('hollerkit-protocol'), '1')
    assert.equal(badProto.body.ok, false)
    assert.equal(badProto.body.error.code, 'unsupported_protocol')

    const okProto = await requestJson('/v1/quests', {
      method: 'GET',
      token: options.agentKey,
      headers: { 'hollerkit-protocol': '1' },
    })
    assert.equal(okProto.status, 200)
    assert.equal(okProto.headers.get('hollerkit-protocol'), '1')
  })

  // 2. Auth & scope enforcement
  await step('auth and scope enforcement across endpoints', async () => {
    const noToken = await requestJson('/v1/quests', { method: 'GET', token: null })
    assert.equal(noToken.status, 401)
    assert.equal(noToken.headers.get('hollerkit-protocol'), '1')

    const badToken = await requestJson('/v1/quests', { method: 'GET', token: 'invalid-token' })
    assert.equal(badToken.status, 401)

    // tester cannot PUT /v1/quests or GET /v1/feedback
    const testerPutQuests = await requestJson('/v1/quests', {
      method: 'PUT',
      token: options.testerToken,
      body: { version: 1, quests: [] },
    })
    assert.equal(testerPutQuests.status, 403)

    const testerGetFeedback = await requestJson('/v1/feedback', {
      method: 'GET',
      token: options.testerToken,
    })
    assert.equal(testerGetFeedback.status, 403)

    // quests:write cannot GET /v1/feedback or POST /v1/feedback
    const ciGetFeedback = await requestJson('/v1/feedback', {
      method: 'GET',
      token: options.questsWriteKey,
    })
    assert.equal(ciGetFeedback.status, 403)

    const ciPostFeedback = await requestJson('/v1/feedback', {
      method: 'POST',
      token: options.questsWriteKey,
      body: { id: randomUUID(), kind: 'report', build: '100', comment: 'nope' },
    })
    assert.equal(ciPostFeedback.status, 403)

    // agentKey cannot PUT /v1/quests or POST /v1/feedback
    const agentPutQuests = await requestJson('/v1/quests', {
      method: 'PUT',
      token: options.agentKey,
      body: { version: 1, quests: [] },
    })
    assert.equal(agentPutQuests.status, 403)

    const agentPostFeedback = await requestJson('/v1/feedback', {
      method: 'POST',
      token: options.agentKey,
      body: { id: randomUUID(), kind: 'report', build: '100', comment: 'nope' },
    })
    assert.equal(agentPostFeedback.status, 403)
  })

  // 3. PUT /v1/quests: sync, version bump, reactivation on reverted edit, and retirement
  await step('PUT /v1/quests syncs, increments versions, reactivates reverted edits, and retires removed quests', async () => {
    // Initial sync: v1 active for both
    const sync1 = await requestJson('/v1/quests', {
      method: 'PUT',
      token: options.questsWriteKey,
      body: {
        version: 1,
        sha: 'aaaa1111',
        quests: [questAlphaV1, questBetaV1],
      },
    })
    assert.equal(sync1.status, 200)
    assert.equal(sync1.body.quests.length, 2)
    assert.deepEqual(sync1.body.retiredIds, [])

    const alpha1 = sync1.body.quests.find((q: any) => q.id === questAlphaV1.id)
    assert.equal(alpha1.version, 1)
    assert.equal(alpha1.status, 'active')
    assert.equal(alpha1.contentHash, computeQuestContentHash(questAlphaV1))

    // Modify questAlpha steps -> creates v2 active, v1 superseded
    const questAlphaV2: QuestDefinitionInput = {
      ...questAlphaV1,
      steps: [...questAlphaV1.steps, 'Verify smooth spring animation'],
    }
    const sync2 = await requestJson('/v1/quests', {
      method: 'PUT',
      token: options.questsWriteKey,
      body: {
        version: 1,
        sha: 'bbbb2222',
        quests: [questAlphaV2, questBetaV1],
      },
    })
    assert.equal(sync2.status, 200)
    const alpha2 = sync2.body.quests.find((q: any) => q.id === questAlphaV1.id)
    assert.equal(alpha2.version, 2)
    assert.equal(alpha2.status, 'active')

    // Edit questAlpha back to its exact v1 functional text (even with different source metadata!)
    // Must reactivate v1 as active without creating v3!
    const questAlphaReverted: QuestDefinitionInput = {
      ...questAlphaV1,
      source: { pr: 99, sha: 'cccc3333', added: '2026-11-08' },
    }
    const sync3 = await requestJson('/v1/quests', {
      method: 'PUT',
      token: options.questsWriteKey,
      body: {
        version: 1,
        sha: 'cccc3333',
        quests: [questAlphaReverted, questBetaV1],
      },
    })
    assert.equal(sync3.status, 200)
    const alphaReactivated = sync3.body.quests.find((q: any) => q.id === questAlphaV1.id)
    assert.equal(alphaReactivated.version, 1, 'Expected v1 to be reactivated, not v3 minted')
    assert.equal(alphaReactivated.status, 'active')

    // Verify v2 is now superseded via GET /v1/quests?status=superseded
    const supersededList = await requestJson('/v1/quests?status=superseded', {
      method: 'GET',
      token: options.agentKey,
    })
    assert.equal(supersededList.status, 200)
    const alphaSuperseded = supersededList.body.quests.filter((q: any) => q.id === questAlphaV1.id)
    assert.ok(alphaSuperseded.some((q: any) => q.version === 2))
    assert.ok(!alphaSuperseded.some((q: any) => q.version === 1))

    // Omit questBeta from manifest -> marks questBeta retired
    const sync4 = await requestJson('/v1/quests', {
      method: 'PUT',
      token: options.questsWriteKey,
      body: {
        version: 1,
        sha: 'dddd4444',
        quests: [questAlphaV1],
      },
    })
    assert.equal(sync4.status, 200)
    assert.deepEqual(sync4.body.retiredIds, [questBetaV1.id])

    const retiredList = await requestJson('/v1/quests?status=retired', {
      method: 'GET',
      token: options.agentKey,
    })
    assert.equal(retiredList.status, 200)
    const betaRetired = retiredList.body.quests.find((q: any) => q.id === questBetaV1.id)
    assert.ok(betaRetired)
    assert.ok(betaRetired.retiredAt)
  })

  // 4 & 5. POST /v1/builds/{build}/manifest and GET /v1/builds/{build}/pending
  const branchDraftQuest: QuestDefinitionInput = {
    id: 'branch-experiment-sheet',
    title: 'Try experimental bottom sheet on feature branch',
    area: 'experiments',
    steps: ['Open sheet', 'Swipe down to dismiss'],
    expect: ['Sheet dismisses cleanly'],
  }

  await step('POST /v1/builds/{build}/manifest records draft quests and GET /v1/builds/{build}/pending returns active pending quests', async () => {
    const manifestRes = await requestJson('/v1/builds/build-100/manifest', {
      method: 'POST',
      token: options.testerToken,
      body: {
        appVersion: '1.2.0',
        quests: [questAlphaV1, branchDraftQuest],
      },
    })
    assert.equal(manifestRes.status, 200)
    assert.equal(manifestRes.body.build, 'build-100')
    assert.equal(manifestRes.body.pendingCount, 2)

    const alphaStatus = manifestRes.body.quests.find((q: any) => q.id === questAlphaV1.id)
    assert.equal(alphaStatus.version, 1)
    assert.equal(alphaStatus.questStatus, 'active')
    assert.equal(alphaStatus.boardStatus, 'pending')

    const draftStatus = manifestRes.body.quests.find((q: any) => q.id === branchDraftQuest.id)
    assert.equal(draftStatus.version, 1)
    assert.equal(draftStatus.questStatus, 'draft')
    assert.equal(draftStatus.boardStatus, 'pending')

    // GET /v1/builds/build-100/pending only returns active pending quests (not draft or retired)
    const pendingResTester = await requestJson('/v1/builds/build-100/pending', {
      method: 'GET',
      token: options.testerToken,
    })
    assert.equal(pendingResTester.status, 200)
    assert.equal(pendingResTester.body.pendingCount, 1)
    assert.equal(pendingResTester.body.quests[0].id, questAlphaV1.id)
    assert.equal(pendingResTester.body.quests[0].version, 1)

    const pendingResAgent = await requestJson('/v1/builds/build-100/pending', {
      method: 'GET',
      token: options.agentKey,
    })
    assert.equal(pendingResAgent.status, 200)
    assert.equal(pendingResAgent.body.pendingCount, 1)
  })

  // 6. POST /v1/uploads & POST /v1/feedback: grant ownership, triage start states, idempotency, board updates
  const reportFeedbackId = randomUUID()
  const failFeedbackId = randomUUID()
  const unsureFeedbackId = randomUUID()
  const passFeedbackId = randomUUID()
  const abandonedFeedbackId = randomUUID()

  await step('POST /v1/uploads and POST /v1/feedback enforce grant ownership, idempotency, and triage start states', async () => {
    const uploadGrant = await requestJson('/v1/uploads', {
      method: 'POST',
      token: options.testerToken,
      body: {
        feedbackId: reportFeedbackId,
        kind: 'image',
        mimeType: 'image/png',
        size: 4096,
      },
    })
    assert.equal(uploadGrant.status, 200)
    assert.ok(uploadGrant.body.key)
    assert.ok(uploadGrant.body.url)
    assert.ok(uploadGrant.body.expiresAt)

    // Attaching grant key to a different feedbackId fails with 400
    const wrongFeedbackRes = await requestJson('/v1/feedback', {
      method: 'POST',
      token: options.testerToken,
      body: {
        id: randomUUID(),
        kind: 'report',
        build: 'build-100',
        comment: 'Trying to steal grant for another feedbackId',
        attachments: [{ key: uploadGrant.body.key, kind: 'image' }],
      },
    })
    assert.equal(wrongFeedbackRes.status, 400)

    // Attaching grant key from another tester fails with 403
    if (options.otherTesterToken) {
      const wrongTesterRes = await requestJson('/v1/feedback', {
        method: 'POST',
        token: options.otherTesterToken,
        body: {
          id: reportFeedbackId,
          kind: 'report',
          build: 'build-100',
          comment: 'Trying to steal grant from another tester',
          attachments: [{ key: uploadGrant.body.key, kind: 'image' }],
        },
      })
      assert.equal(wrongTesterRes.status, 403)
    }

    // Properly submit report with the upload grant and out-of-order events
    const reportRes = await requestJson('/v1/feedback', {
      method: 'POST',
      token: options.testerToken,
      body: {
        id: reportFeedbackId,
        kind: 'report',
        build: 'build-100',
        appVersion: '1.2.0',
        device: 'iPhone 16 Pro',
        os: 'iOS 19.0',
        comment: 'Feed card flickers when returning.',
        metadata: { area: 'feed' },
        events: [
          { offsetSeconds: 4.5, kind: 'mark', payload: { label: 'flicker' } },
          { offsetSeconds: 1.2, kind: 'navigation', payload: { screen: 'FeedDetail' } },
        ],
        attachments: [
          { key: uploadGrant.body.key, kind: 'image', offsetSeconds: 4.5 },
        ],
      },
    })
    assert.equal(reportRes.status, 201)
    assert.equal(reportRes.body.idempotent, false)
    assert.equal(reportRes.body.feedback.triageStatus, 'new')

    // Re-POSTing the exact same feedback.id (even with the now-consumed attachment key) is idempotent (200)
    const replayRes = await requestJson('/v1/feedback', {
      method: 'POST',
      token: options.testerToken,
      body: {
        id: reportFeedbackId,
        kind: 'report',
        build: 'build-100',
        comment: 'Feed card flickers when returning.',
        attachments: [
          { key: uploadGrant.body.key, kind: 'image', offsetSeconds: 4.5 },
        ],
      },
    })
    assert.equal(replayRes.status, 200)
    assert.equal(replayRes.body.idempotent, true)
    assert.equal(replayRes.body.feedback.id, reportFeedbackId)

    // Submit quest_run with result: 'fail' -> triageStatus = 'new'
    const failRes = await requestJson('/v1/feedback', {
      method: 'POST',
      token: options.testerToken,
      body: {
        id: failFeedbackId,
        kind: 'quest_run',
        questId: questAlphaV1.id,
        questVersion: 1,
        result: 'fail',
        build: 'build-100',
        comment: 'Scroll position jumped to top.',
        stepsChecked: [true, true, false],
      },
    })
    assert.equal(failRes.status, 201)
    assert.equal(failRes.body.feedback.triageStatus, 'new')

    // Check board status after fail -> 'failed'
    const manifestAfterFail = await requestJson('/v1/builds/build-100/manifest', {
      method: 'POST',
      token: options.testerToken,
      body: { quests: [questAlphaV1] },
    })
    assert.equal(manifestAfterFail.body.quests[0].boardStatus, 'failed')

    // Submit quest_run with result: 'unsure' -> triageStatus = 'new'
    const unsureRes = await requestJson('/v1/feedback', {
      method: 'POST',
      token: options.testerToken,
      body: {
        id: unsureFeedbackId,
        kind: 'quest_run',
        questId: questAlphaV1.id,
        questVersion: 1,
        result: 'unsure',
        build: 'build-100',
        comment: 'Transition felt slightly stuttery.',
      },
    })
    assert.equal(unsureRes.status, 201)
    assert.equal(unsureRes.body.feedback.triageStatus, 'new')

    // Submit quest_run with result: 'abandoned' -> triageStatus = null
    const abandonedRes = await requestJson('/v1/feedback', {
      method: 'POST',
      token: options.testerToken,
      body: {
        id: abandonedFeedbackId,
        kind: 'quest_run',
        questId: questAlphaV1.id,
        questVersion: 1,
        result: 'abandoned',
        build: 'build-100',
      },
    })
    assert.equal(abandonedRes.status, 201)
    assert.equal(abandonedRes.body.feedback.triageStatus, null)

    // Submit quest_run with result: 'pass' -> triageStatus = null
    const passRes = await requestJson('/v1/feedback', {
      method: 'POST',
      token: options.testerToken,
      body: {
        id: passFeedbackId,
        kind: 'quest_run',
        questId: questAlphaV1.id,
        questVersion: 1,
        result: 'pass',
        build: 'build-100',
        stepsChecked: [true, true, true],
      },
    })
    assert.equal(passRes.status, 201)
    assert.equal(passRes.body.feedback.triageStatus, null)
  })

  await step('board status reflects pass, and updating quest to a new version makes it pending again', async () => {
    const manifestAfterPass = await requestJson('/v1/builds/build-100/manifest', {
      method: 'POST',
      token: options.testerToken,
      body: { quests: [questAlphaV1] },
    })
    assert.equal(manifestAfterPass.status, 200)
    assert.equal(manifestAfterPass.body.quests[0].boardStatus, 'passed')
    assert.equal(manifestAfterPass.body.pendingCount, 0)

    const pendingAfterPass = await requestJson('/v1/builds/build-100/pending', {
      method: 'GET',
      token: options.testerToken,
    })
    assert.equal(pendingAfterPass.status, 200)
    assert.equal(pendingAfterPass.body.pendingCount, 0)

    // Update questAlpha to v3 (new instructions) -> becomes pending again!
    const questAlphaV3: QuestDefinitionInput = {
      ...questAlphaV1,
      expect: ['Back returns to the same card and preserves video playback state'],
    }
    const syncV3 = await requestJson('/v1/quests', {
      method: 'PUT',
      token: options.questsWriteKey,
      body: {
        version: 1,
        sha: 'eeee5555',
        quests: [questAlphaV3],
      },
    })
    assert.equal(syncV3.status, 200)
    assert.equal(syncV3.body.quests[0].version, 3)

    const manifestAfterV3 = await requestJson('/v1/builds/build-100/manifest', {
      method: 'POST',
      token: options.testerToken,
      body: { quests: [questAlphaV3] },
    })
    assert.equal(manifestAfterV3.status, 200)
    assert.equal(manifestAfterV3.body.quests[0].boardStatus, 'pending')
    assert.equal(manifestAfterV3.body.pendingCount, 1)

    const pendingAfterV3 = await requestJson('/v1/builds/build-100/pending', {
      method: 'GET',
      token: options.testerToken,
    })
    assert.equal(pendingAfterV3.status, 200)
    assert.equal(pendingAfterV3.body.pendingCount, 1)
    assert.equal(pendingAfterV3.body.quests[0].version, 3)

    // Now pass v3 so it becomes retirable
    const passV3Res = await requestJson('/v1/feedback', {
      method: 'POST',
      token: options.testerToken,
      body: {
        id: randomUUID(),
        kind: 'quest_run',
        questId: questAlphaV3.id,
        questVersion: 3,
        result: 'pass',
        build: 'build-100',
      },
    })
    assert.equal(passV3Res.status, 201)
  })

  // 7 & 8. GET /v1/feedback, GET /v1/feedback/{id}, PUT /v1/feedback/{id}/triage
  await step('GET /v1/feedback filters untriaged items, GET /v1/feedback/{id} sorts events and signs URLs, and PUT triage updates atomically', async () => {
    const inboxRes = await requestJson('/v1/feedback?triage=new', {
      method: 'GET',
      token: options.agentKey,
    })
    assert.equal(inboxRes.status, 200)
    const inboxIds = new Set(inboxRes.body.items.map((item: any) => item.id))
    assert.ok(inboxIds.has(reportFeedbackId), 'report should be in ?triage=new')
    assert.ok(inboxIds.has(failFeedbackId), 'fail should be in ?triage=new')
    assert.ok(inboxIds.has(unsureFeedbackId), 'unsure should be in ?triage=new')
    assert.ok(!inboxIds.has(passFeedbackId), 'pass must NEVER appear in ?triage=new')
    assert.ok(!inboxIds.has(abandonedFeedbackId), 'abandoned must NEVER appear in ?triage=new')

    // GET /v1/feedback/{id} for reportFeedbackId
    const detailRes = await requestJson(`/v1/feedback/${reportFeedbackId}`, {
      method: 'GET',
      token: options.agentKey,
    })
    assert.equal(detailRes.status, 200)
    assert.equal(detailRes.body.feedback.id, reportFeedbackId)
    assert.equal(detailRes.body.events.length, 2)
    assert.equal(detailRes.body.events[0].offsetSeconds, 1.2)
    assert.equal(detailRes.body.events[1].offsetSeconds, 4.5)
    assert.equal(detailRes.body.attachments.length, 1)
    assert.ok(detailRes.body.attachments[0].url.startsWith('http'))
    assert.ok(detailRes.body.attachments[0].expiresAt)

    // GET /v1/feedback/{id} for failFeedbackId includes quest version record
    const failDetailRes = await requestJson(`/v1/feedback/${failFeedbackId}`, {
      method: 'GET',
      token: options.agentKey,
    })
    assert.equal(failDetailRes.status, 200)
    assert.ok(failDetailRes.body.quest)
    assert.equal(failDetailRes.body.quest.id, questAlphaV1.id)
    assert.equal(failDetailRes.body.quest.version, 1)

    // PUT /v1/feedback/{id}/triage
    const triage1 = await requestJson(`/v1/feedback/${reportFeedbackId}/triage`, {
      method: 'PUT',
      token: options.agentKey,
      body: {
        status: 'triaged',
        summary: 'Reproduced scroll flicker in FeedDetailView.',
        links: ['https://github.com/acme/app/pull/101'],
        actor: 'codex-agent',
      },
    })
    assert.equal(triage1.status, 200)
    assert.equal(triage1.body.feedback.triageStatus, 'triaged')
    assert.equal(triage1.body.feedback.triageSummary, 'Reproduced scroll flicker in FeedDetailView.')
    assert.deepEqual(triage1.body.feedback.links, ['https://github.com/acme/app/pull/101'])

    const triage2 = await requestJson(`/v1/feedback/${reportFeedbackId}/triage`, {
      method: 'PUT',
      token: options.agentKey,
      body: {
        status: 'resolved',
        summary: 'Fixed in PR #101.',
        links: ['https://github.com/acme/app/pull/101'],
        actor: 'codex-agent',
      },
    })
    assert.equal(triage2.status, 200)
    assert.equal(triage2.body.feedback.triageStatus, 'resolved')

    const detailAfterTriage = await requestJson(`/v1/feedback/${reportFeedbackId}`, {
      method: 'GET',
      token: options.agentKey,
    })
    assert.equal(detailAfterTriage.status, 200)
    assert.equal(detailAfterTriage.body.triage.length, 2)
    assert.equal(detailAfterTriage.body.triage[0].status, 'triaged')
    assert.equal(detailAfterTriage.body.triage[1].status, 'resolved')
  })

  // 9. GET /v1/quests retirable filter
  await step('GET /v1/quests filters by status=active and passedOnCurrentVersion=true', async () => {
    const retirable = await requestJson('/v1/quests?status=active&passedOnCurrentVersion=true', {
      method: 'GET',
      token: options.agentKey,
    })
    assert.equal(retirable.status, 200)
    assert.equal(retirable.body.quests.length, 1)
    assert.equal(retirable.body.quests[0].id, questAlphaV1.id)
    assert.equal(retirable.body.quests[0].version, 3)
    assert.equal(retirable.body.quests[0].passedOnCurrentVersion, true)
    assert.ok(retirable.body.quests[0].counts.pass >= 1)

    const unpassedActive = await requestJson('/v1/quests?status=active&passedOnCurrentVersion=false', {
      method: 'GET',
      token: options.agentKey,
    })
    assert.equal(unpassedActive.status, 200)
    assert.equal(unpassedActive.body.quests.length, 0)
  })

  // 10. Payload limits validation
  await step('enforces JSON, text, image count, image size, and mark count limits', async () => {
    // Oversized JSON (> maxJsonBytes)
    const hugeJson = JSON.stringify({
      id: randomUUID(),
      kind: 'report',
      build: '100',
      metadata: { padding: 'x'.repeat(limits.maxJsonBytes + 1024) },
    })
    const oversizedJsonRes = await requestJson('/v1/feedback', {
      method: 'POST',
      token: options.testerToken,
      rawBody: hugeJson,
    })
    assert.equal(oversizedJsonRes.status, 413)
    assert.equal(oversizedJsonRes.body.error.code, 'body_too_large')

    // > maxTextChars comment (within maxJsonBytes)
    if (limits.maxTextChars + 1 < limits.maxJsonBytes - 512) {
      const longTextRes = await requestJson('/v1/feedback', {
        method: 'POST',
        token: options.testerToken,
        body: {
          id: randomUUID(),
          kind: 'report',
          build: '100',
          comment: 'a'.repeat(limits.maxTextChars + 1),
        },
      })
      assert.equal(longTextRes.status, 413)
      assert.equal(longTextRes.body.error.code, 'text_too_large')
    }

    // > maxImageBytes image upload grant
    const hugeImageGrantRes = await requestJson('/v1/uploads', {
      method: 'POST',
      token: options.testerToken,
      body: {
        feedbackId: randomUUID(),
        kind: 'image',
        mimeType: 'image/png',
        size: limits.maxImageBytes + 1,
      },
    })
    assert.equal(hugeImageGrantRes.status, 413)
    assert.equal(hugeImageGrantRes.body.error.code, 'image_too_large')

    // > maxImages images on feedback
    const tooManyImagesRes = await requestJson('/v1/feedback', {
      method: 'POST',
      token: options.testerToken,
      body: {
        id: randomUUID(),
        kind: 'report',
        build: '100',
        attachments: Array.from({ length: limits.maxImages + 1 }, (_, idx) => ({
          key: `fake-key-${idx}`,
          kind: 'image',
        })),
      },
    })
    assert.equal(tooManyImagesRes.status, 413)
    assert.equal(tooManyImagesRes.body.error.code, 'too_many_images')

    // > maxMarks marks on feedback
    const tooManyMarksRes = await requestJson('/v1/feedback', {
      method: 'POST',
      token: options.testerToken,
      body: {
        id: randomUUID(),
        kind: 'report',
        build: '100',
        events: Array.from({ length: limits.maxMarks + 1 }, (_, idx) => ({
          offsetSeconds: idx,
          kind: 'mark',
        })),
      },
    })
    assert.equal(tooManyMarksRes.status, 413)
    assert.equal(tooManyMarksRes.body.error.code, 'too_many_marks')
  })

  return { ok: true, steps }
}
