# AgentOS migration contracts — v1.0

Contracts for the CAP + DACKIE (Base) → AGENTOS (Robinhood) migration. Foundry + pnpm workspace. v1.0 release with AI-assisted security reviews; see audits and README for details.

## Structure

- `docs`: the migration plan specification, holder snapshots, and long-lock data. See [docs/README.md](docs/README.md).
- `projects/migration`: `MigrationVault` (Base) and `MerkleVestingDistributor` (Robinhood), tests,
  deploy scripts and the off-chain claim tree tooling. Start with its [README](projects/migration/README.md).

## Commands

```bash
pnpm install
pnpm run setup      # forge libs (fresh clone only)
pnpm run build:all
pnpm run test:all
```
