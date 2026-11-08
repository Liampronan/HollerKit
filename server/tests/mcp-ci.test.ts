import { execFileSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { resolve } from 'node:path'
import test from 'node:test'

test('typechecks, builds, and passes hollerkit-mcp test suite', () => {
  const mcpDir = resolve(import.meta.dirname, '../../mcp')
  const mcpTscBin = resolve(mcpDir, 'node_modules/.bin/tsc')
  const mcpTypesRoot = resolve(mcpDir, 'node_modules/@types')

  if (process.env.CI === 'true' || !existsSync(mcpTscBin)) {
    execFileSync('npm', ['ci'], {
      cwd: mcpDir,
      stdio: 'pipe',
    })
  }

  const tscBin = existsSync(mcpTscBin)
    ? mcpTscBin
    : resolve(import.meta.dirname, '../node_modules/.bin/tsc')
  const typesRoot = existsSync(mcpTypesRoot)
    ? mcpTypesRoot
    : resolve(import.meta.dirname, '../node_modules/@types')

  execFileSync(tscBin, ['-p', 'tsconfig.json', '--typeRoots', typesRoot], {
    cwd: mcpDir,
    stdio: 'pipe',
  })

  execFileSync(tscBin, ['-p', 'tsconfig.build.json', '--typeRoots', typesRoot], {
    cwd: mcpDir,
    stdio: 'pipe',
  })

  execFileSync(
    process.execPath,
    ['--test', '--experimental-strip-types', 'tests/mcp.test.ts'],
    {
      cwd: mcpDir,
      stdio: 'pipe',
    },
  )
})
