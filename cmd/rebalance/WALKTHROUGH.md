# Understanding the workspace rebalancer

This guide explains [main.go](./main.go) step by step. It describes the current
implementation, including its limitations—not just what a rebalancer could do
in theory.

## 1. The big picture

The program answers two questions:

1. How many ordinary workspaces are stored on each KCP shard?
2. Which workspaces should move so that the counts are approximately equal?

By default, it only prints an answer. With `--apply`, it also asks KCP to perform
the moves.

For example:

```text
Before: root=5, shard-01=1, shard-02=3
Move one workspace from root to shard-01
Move another workspace from root to shard-01
After:  root=3, shard-01=3, shard-02=3
```

The program does not copy etcd records itself. It creates migration requests,
and KCP's migration controllers do the actual transfer.

## 2. Kubernetes and KCP vocabulary

### The hosting Kubernetes cluster

Your local kind cluster runs KCP and its supporting components.

Think of it as the infrastructure layer. It runs the KCP server processes,
etcd instances, and operators.

### Pod, Service, and namespace

- A **Pod** runs one or more containers. Your KCP server runs in a Pod.
- A **Service** provides a stable network entry point to selected Pods.
  The program discovers Services such as `root-kcp` rather than hardcoding
  changing Pod names.
- A **namespace** groups Kubernetes resources. In this installation, KCP's
  hosting resources are in the `default` namespace.

A namespace is not the same thing as a KCP workspace.

### KCP workspace and logical cluster

A workspace provides a Kubernetes-like API environment.

Its **logical cluster** is the backing API/storage identity. For example:

```text
Human-readable workspace path: root:team-1
Internal logical cluster name: 2gojve20tvtqgbul
```

The parent stores a `Workspace` object describing the child. The child's actual
logical cluster can be stored on a different shard.

This is why counting `Workspace` objects in root would not correctly measure
how many workspaces each shard actually hosts.

### Shard and etcd

A shard is a KCP API server/storage partition that hosts logical clusters.
Its data is stored in etcd, a key-value database.

Moving a workspace means transferring its backing logical cluster to another
shard, including its stored resource data.

### Kubeconfig

A kubeconfig contains connection settings, server trust information, and
authentication information.

This program uses two:

| Default file | Purpose |
| --- | --- |
| `.kube/kind.kubeconfig` | Access the hosting Kubernetes API to find Services and open tunnels |
| `.kube/kcp-wildcard.kubeconfig` | Authenticate directly to KCP shards to inventory clusters and request migrations |

These are different APIs with different certificate trust. Administrator
access to kind does not automatically grant administrator access to KCP.

### Operator and controller

A controller repeatedly watches API objects and takes actions to make reality
match their requested state.

An operator packages controllers for managing an application such as KCP.

For migration, the program creates a `LogicalClusterMigration` API object.
KCP controllers notice it, move the data, and update its status.

## 3. A few Go basics used throughout the file

### Package and imports

```go
package main
```

This declares an executable program. Its entry point is the `main` function.

The import block brings in standard Go libraries and Kubernetes client
libraries. For example:

- `fmt`: formatted output and errors.
- `flag`: command-line arguments.
- `context`: cancellation and operation lifetime.
- `net/http`: HTTP requests.
- `os/exec`: starting the external `kubectl` command.
- `client-go`: Kubernetes configuration and API clients.

Aliases such as `corev1` distinguish Kubernetes packages with otherwise similar
names.

### Structs, slices, and maps

A **struct** groups named fields:

```go
type workspace struct {
    Cluster string
    Path    string
}
```

A **slice** is a variable-length sequence. `[]workspace` means a sequence of
workspace values.

A **map** associates keys with values:

```go
map[string][]workspace
```

This means: “for each shard name, store a sequence of its workspaces.”

### Errors and multiple return values

Go functions commonly return a result and an error:

```go
config, err := clientcmd.BuildConfigFromFlags("", *hosting)
if err != nil {
    return err
}
```

`:=` declares variables and assigns values. `nil` means there is no error here.
Returning an error lets the caller decide how to report it.

### Pointers

`*rest.Config` is a pointer to a configuration object.

`flag.String` also returns a pointer. In `*hosting`, the `*` reads the value
that pointer refers to.

### Deferred cleanup

```go
defer closeForward()
```

This schedules cleanup when the containing function returns, whether it
succeeds or returns an error. Deferred functions run in reverse registration
order.

## 4. Data structures: what the program remembers

The file defines three small structs:

| Type | Meaning |
| --- | --- |
| `workspace` | Internal logical cluster name and readable workspace path |
| `move` | A workspace plus source and destination shard names |
| `shard` | Shard name, Service name, and API connection configuration |

It also declares `migrationGVR`.

**GVR** means Group, Version, Resource:

```text
Group:    migration.kcp.io
Version:  v1alpha1
Resource: logicalclustermigrations
```

Together these identify the API endpoint used for migration resources.
This is similar to knowing which table or collection a database client should
operate on.

## 5. Entry point: `main`

`main` calls `run`.

If `run` returns an error, `main`:

1. Writes the error to standard error.
2. Exits with status code `1`.

An exit code of zero normally signals success; a nonzero code signals failure.
This matters when running the program from scripts.

Keeping most logic in `run` allows deferred cleanup to finish before `main`
calls `os.Exit`.

## 6. Read command-line options

At the start of `run`, the program defines these flags:

| Flag | Default | Meaning |
| --- | --- | --- |
| `--hosting-kubeconfig` | `.kube/kind.kubeconfig` | Hosting cluster credentials |
| `--kcp-kubeconfig` | `.kube/kcp-wildcard.kubeconfig` | KCP credentials |
| `--namespace` | `default` | Where to discover hosting Services |
| `--apply` | `false` | Whether to actually submit migrations |
| `--migration-timeout` | `10m` | Maximum polling time per migration |

`flag.Parse()` reads the supplied arguments.

Unexpected positional arguments and a nonpositive migration timeout are rejected.

Run from the repository root because the default paths are relative to the
current working directory:

```sh
go run ./cmd/rebalance
```

This previews a plan. The disruptive version is:

```sh
go run ./cmd/rebalance --apply
```

## 7. Set up cancellation

`signal.NotifyContext` creates a context that is cancelled when:

- You press Ctrl+C.
- The process receives SIGTERM, a common shutdown signal.

The context is passed to network operations and child processes so they can
stop when the program is asked to exit.

Cancelling the program does **not** cancel a migration already submitted to
KCP. That migration is managed by server-side controllers.

## 8. Load credentials and create clients

The program loads both kubeconfigs.

It creates a typed Kubernetes client for the hosting cluster:

```go
hostClient, err := kubernetes.NewForConfig(hostConfig)
```

“Typed” means the library knows the structure of built-in Kubernetes objects
such as Services.

The KCP configuration is initially just loaded and stored. Later it is copied
and adjusted for each shard.

Both configurations get a 30-second HTTP timeout. This is separate from the
10-minute overall migration polling timeout: one limits individual HTTP
requests; the other limits waiting for a migration to finish.

## 9. Discover the shard Services

The program lists Services in the selected hosting namespace using labels:

```text
app.kubernetes.io/managed-by=kcp-operator
app.kubernetes.io/component in (rootshard,shard)
```

Labels are metadata used to identify and select Kubernetes objects.

The `hasHTTPS` helper further restricts the results to Services with a port
named `https` whose Service port is `6443`.

The label is read from the generated **Service**, not from the `Shard` custom
resource. These are separate Kubernetes objects with their own metadata.
For example, `Shard/shard-01` does not need to carry this label, while its
operator-generated `Service/shard-01-shard-kcp` carries:

```yaml
metadata:
  labels:
    app.kubernetes.io/instance: shard-01
```

Inspect the Service label using the hosting Kubernetes kubeconfig:

```sh
kubectl --kubeconfig=.kube/kind.kubeconfig -n default \
  get service shard-01-shard-kcp \
  -o jsonpath='{.metadata.labels.app\.kubernetes\.io/instance}{"\n"}'
```

For every matching Service, the program:

1. Reads the shard name from the `app.kubernetes.io/instance` label.
2. Rejects missing or duplicate shard names.
3. Creates a connection to the Service.
4. Stores the resulting shard connection settings.

It requires exactly one discovered root shard and at least one shard overall.
It then sorts shards by name so subsequent behavior is reproducible.

## 10. Open a temporary connection to each shard

The `forward` helper starts an external command equivalent to:

```sh
kubectl --kubeconfig=.kube/kind.kubeconfig -n default \
  port-forward --address=127.0.0.1 svc/root-kcp :6443
```

The missing port before `:6443` asks `kubectl` to choose an available local port.

For example:

```text
127.0.0.1:53123 -> Service port 6443
```

The program can now access that shard at `https://127.0.0.1:53123`.
The listener is loopback-only, so it is not exposed on your machine's external
network interfaces.

### How does Go know the tunnel is ready?

The helper starts a **goroutine**, a concurrently running function, to read
`kubectl`'s standard output.

It looks for a readiness line such as:

```text
Forwarding from 127.0.0.1:53123 -> 6443
```

A regular expression extracts the port. A **channel** passes that address
back to the waiting function.

The `select` statement waits for whichever happens first:

- A ready address arrives.
- The output stream ends.
- A 30-second timer expires.
- The context is cancelled.

The output-reading goroutine continues draining output while the tunnel runs.
Cleanup cancels the owned process and waits for it to exit.

### Why change the TLS server name?

The certificate identifies a name such as:

```text
root-kcp.default.svc.cluster.local
```

But the local TCP connection uses `127.0.0.1`.

Setting `TLSClientConfig.ServerName` tells the TLS client which certificate
identity to verify. This preserves certificate verification; it does not
disable TLS checks.

The program retains the kubeconfig's CA trust and client credentials.

### Root configuration

The root shard gets an additional configuration whose URL ends with:

```text
/clusters/root
```

That configuration targets the root logical cluster, where the program later
creates migration resources.

## 11. Build an inventory with `inventorySnapshot`

For each shard, the program creates an authenticated HTTP client and sends:

```text
GET /clusters/*/apis/core.kcp.io/v1alpha1/logicalclusters
```

The `*` is KCP's wildcard cluster selector. This request lists logical clusters
stored on that particular shard. It does not aggregate every shard.

Because the program loops over all discovered shards, it obtains an installation
inventory.

### Validate the HTTP response

`readClusters`:

1. Makes sure the HTTP status is `200 OK`.
2. If not, returns an error containing up to 4096 bytes of the response.
3. Decodes the JSON into an unstructured list.
4. Confirms the returned kind is `LogicalClusterList`.
5. Closes the response body afterward.

An **unstructured** object represents Kubernetes JSON without requiring a
dedicated Go struct for that custom resource.

### Decide which logical clusters count

The inventory excludes:

- The logical cluster named `root`.
- Every logical cluster whose name begins with `system:`.

For the remaining objects, it requires:

- A nonempty `kcp.io/cluster` annotation.
- A `kcp.io/path` annotation starting with `root:`.
- Status phase `Ready`.
- No duplicate logical cluster name across discovered shards.

It stops on invalid or unstable placement rather than guessing.

The result resembles:

```text
root     -> [team-2, team-3, team-5, team-8, team-9]
shard-01 -> [team-7]
shard-02 -> [team-1, team-4, team-6]
```

Internally it stores both the readable path and the logical cluster identifier.

This is a sequence of requests, not an atomic snapshot. Other operations could
change placement while those requests are being made.

## 12. Calculate a plan with `plan`

This function only calculates. It does not make API requests.

First it copies the candidate workspace slices, so planning does not remove
items from the original inventory.

It sorts:

- Shard names alphabetically.
- Candidate workspaces by internal logical cluster name.

The ordering makes the plan deterministic for the same inventory. It does not
select workspaces based on data size, CPU usage, or business priority.

It then repeatedly:

1. Finds the shard with the highest workspace count.
2. Finds the shard with the lowest workspace count.
3. Stops if the difference is at most one.
4. Otherwise selects one candidate from the fullest shard.
5. Records a move to the least populated shard.
6. Adjusts the simulated counts and repeats.

For `5, 1, 3`:

```text
Iteration 1: 5,1,3 -> 4,2,3
Iteration 2: 4,2,3 -> 3,3,3
Stop.
```

For ten workspaces across three shards, perfect equality is impossible.
A result such as `4,3,3` is considered balanced.

Equal counts do not guarantee equal load. One large workspace could use more
resources than several small ones combined.

## 13. Print the result and stop unless `--apply` was provided

The program prints:

- Current and planned counts per shard.
- Each proposed move.

Without `--apply`, it returns successfully here.

Dry-run still reads APIs and opens temporary tunnels, but does not create
migration objects or modify Kubernetes/KCP resources.

## 14. In apply mode, check for active migrations

The program creates a **dynamic client** using the root configuration.

A dynamic client works with resources identified by GVR instead of requiring
a compiled Go type for each custom API.

It selects `logicalclustermigrations` and lists existing objects in root.

Any object whose phase is neither `Completed` nor `Failed` blocks the operation.
An empty phase also blocks it.

This check prevents knowingly overlapping with a migration already in root.
It does not check migration objects in every other workspace and is not a
distributed lock against another program starting immediately afterward.

The migration API must already be bound in root, and the migration feature
must already be enabled. This program does not configure those prerequisites.

## 15. Recheck placement before each move

Before submitting a migration, the program inventories all shards again.

`sameInventory` checks that the current workspace identities and paths on each
shard match the expected inventory. It ignores ordering.

If a workspace was added, removed, or moved, the program stops and asks for a
new run instead of applying an outdated plan.

This is a safety check, not a transaction. Placement could still change after
the check. Run the program without concurrent rebalancers or other
placement-changing automation.

## 16. Submit one migration with `migrate`

For each planned move, the program creates an object equivalent to:

```yaml
apiVersion: migration.kcp.io/v1alpha1
kind: LogicalClusterMigration
metadata:
  generateName: rebalance-
spec:
  logicalCluster: 1asxazfkj5vnils8
  destinationShard: shard-01
```

`generateName` tells the API server to generate a unique name starting with
`rebalance-`.

The internal logical cluster name is used—not the readable workspace path.

Notice that the source shard is not in this request. KCP resolves the source
from the logical cluster's placement.

### What KCP does next

The server-side migration controllers manage preparation, data transfer,
source cleanup, and destination finalization.

The workspace can be unavailable during this process. This is not a zero-downtime
load balancer.

### What the Go program does while waiting

`wait.PollUntilContextTimeout` reads the migration object:

- Immediately once.
- Then approximately every two seconds.

It returns success on `Completed`, an error on `Failed`, and otherwise keeps
waiting until timeout or cancellation.

API read failures also stop the wait; the current code does not retry those
errors as if they were successful polls.

The program moves one workspace at a time. It does not launch migrations
in parallel.

## 17. Update the expected inventory

After a migration reports `Completed`, the program:

1. Removes the workspace from its in-memory source slice.
2. Appends it to the destination slice.

The removal expression:

```go
append(items[:i], items[i+1:]...)
```

joins the entries before index `i` with the entries after index `i`.
The `...` expands a slice into the individual arguments accepted by `append`.

This updates the program's expected placement for its next safety check.
It does not itself move any server-side data.

## 18. Verify the final result

After all migrations finish, the program reads the shard inventories again.

It requires both:

1. Actual placement matches the expected placement.
2. Calling `plan` on that inventory produces no further moves.

The second check verifies that counts differ by at most one.

Only then does it print:

```text
Verified: shard workspace counts differ by at most one.
```

## 19. Cleanup and failures

When `run` returns, deferred cleanup closes the temporary port-forwards.
The program does not change your current kubectl context.

If something fails:

- It stops instead of continuing with later migrations.
- Completed migrations are not rolled back.
- Submitted migrations can continue running server-side.
- Created migration objects are retained.
- After a timeout, inspect the migration before starting another run.

A successful dry-run does not prove that the migration API is bound or that
the migration controllers are enabled: those paths are only exercised in apply
mode.

## 20. What this program is—and is not

It is a one-shot, count-based administrative CLI.

It is not:

- A continuously running controller.
- A CPU-, memory-, or storage-aware scheduler.
- A distributed system with a global rebalance lock.
- An implementation of the underlying data-transfer protocol.
- A way to migrate workspaces without downtime.

Nested workspaces count separately; moving a parent does not implicitly move
its children.

## 21. Execution flow at a glance

```text
main
  |
  +-- run
       |
       +-- Parse flags and configure cancellation
       +-- Load hosting and KCP kubeconfigs
       +-- Discover shard Services
       +-- Open per-shard port-forwards
       +-- inventorySnapshot
       |    +-- readClusters
       +-- plan
       +-- Print counts and proposed moves
       |
       +-- No --apply? Return; clean up tunnels
       |
       +-- Check existing migrations in root
       +-- For each move:
       |    +-- inventorySnapshot
       |    +-- sameInventory
       |    +-- migrate: create request and poll completion
       |    +-- Update expected inventory
       +-- Verify final placement and balance
       +-- Return; clean up tunnels
```

## 22. Suggested reading and practice

1. Run `go run ./cmd/rebalance` and compare the table with the shard inventory.
2. Read `workspace`, `move`, and `shard` to understand the data being passed around.
3. Read `plan` first: it contains the core balancing idea without networking.
4. Read `inventorySnapshot` to see how API data becomes that planning input.
5. Read `migrate` to see how the program delegates movement to KCP.
6. Read `forward` last: process management and concurrency make it the most
   mechanically involved helper.

Run the related tests with:

```sh
go test ./cmd/rebalance
```

The tests cover planning examples, inventory validation, placement comparison,
and migration submission/polling behavior using fake APIs. They do not perform
real workspace migrations.
