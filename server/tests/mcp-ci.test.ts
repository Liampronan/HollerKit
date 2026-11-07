import { execFileSync } from 'node:child_process'
import { resolve } from 'node:path'
import test from 'node:test'

test('typechecks, builds, and passes hollerkit-mcp test suite', () => {
  const mcpDir = resolve(import.meta.dirname, '../../mcp')
  const tscBin = resolve(import.meta.dirname, '../node_modules/.bin/tsc')
  const serverTypesRoot = resolve(import.meta.dirname, '../node_modules/@types')

  execFileSync(tscBin, ['-p', 'tsconfig.json', '--typeRoots', serverTypesRoot], {
    cwd: mcpDir,
    stdio: 'pipe',
  })

  execFileSync(tscBin, ['-p', 'tsconfig.build.json', '--typeRoots', serverTypesRoot], {
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
