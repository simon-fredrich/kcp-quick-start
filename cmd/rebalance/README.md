# Workspace rebalancer

For a beginner-friendly explanation of Kubernetes concepts, Go syntax, and the
program's execution flow, see the [step-by-step walkthrough](./WALKTHROUGH.md).

Run from the repository root:

```sh
go run ./cmd/rebalance
```

Default behavior is read-only: discover operator-managed KCP shard Services in
`default`, count each non-system backing logical cluster, and print a
deterministic plan. `root` and `system:*` are excluded. All discovered shards,
including the root shard, participate. Target counts differ by at most one.

The CLI opens and cleans up its own loopback port-forwards using `kubectl`.
It uses `.kube/kind.kubeconfig` for hosting cluster access and
`.kube/kcp-wildcard.kubeconfig` for KCP administrator access. Generate the
latter using [the certificate script](../../hack/generate-kcp-wildcard-kubeconfig.sh).
Flags allow overriding both kubeconfigs and the namespace.

## Executing a plan

```sh
go run ./cmd/rebalance --apply
```

This is disruptive: each migrating workspace temporarily becomes unavailable.
Run only one rebalancer and stop other placement-changing automation and
workspace creation/deletion during execution. There is no distributed lock or
atomic cross-shard snapshot. The CLI rejects non-Ready or duplicate logical
clusters, checks for active migrations in root, and checks placement before
every move, but cannot eliminate concurrent-change races.

Prerequisites:

- `LogicalClusterMigration=true` enabled on all shards and the cache.
- Migration API bound in `root`, as in the
  [KCP migration guide](https://docs.kcp.io/kcp/v0.33/concepts/sharding/migration/).
- Valid unrestricted KCP administrator certificate trusted by every shard.
- All managed shards in the selected namespace belong to the same installation.

Migrations are created in `root` and processed sequentially. The CLI waits for
`Completed` before starting the next one and verifies the final placement.
On errors or a timeout it stops; already completed migrations are not rolled
back. A migration already submitted can continue after the CLI exits. Inspect
it before retrying. Completed migration objects are retained for audit.
The default per-migration timeout is 10 minutes (`--migration-timeout`).

Counts describe logical clusters actually stored on each shard, not Workspace
objects stored in their parents. Nested workspaces count individually and are
migrated individually. System clusters do not contribute to the balance.

Tests:

```sh
go test ./cmd/rebalance
```
