package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

type workspace struct {
	Cluster string
	Path    string
}

type move struct {
	Workspace workspace
	From, To  string
}

type shard struct {
	Name, Service string
	Config        *rest.Config
}

var migrationGVR = schema.GroupVersionResource{
	Group: "migration.kcp.io", Version: "v1alpha1", Resource: "logicalclustermigrations",
}

// main reports errors and exits with a nonzero status on failure.
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// run discovers shards, prints a balancing plan, and executes it only with --apply.
func run() error {
	// Default to a read-only preview; migration requires an explicit --apply.
	hosting := flag.String("hosting-kubeconfig", ".kube/kind.kubeconfig", "Hosting Kubernetes kubeconfig")
	kcp := flag.String("kcp-kubeconfig", ".kube/kcp-wildcard.kubeconfig", "KCP system:masters kubeconfig")
	namespace := flag.String("namespace", "default", "Namespace containing the KCP shards")
	apply := flag.Bool("apply", false, "Execute migrations (default: print plan only)")
	timeout := flag.Duration("migration-timeout", 10*time.Minute, "Maximum wait for each migration")
	flag.Parse()
	if flag.NArg() != 0 || *timeout <= 0 {
		return fmt.Errorf("unexpected positional arguments or non-positive migration timeout")
	}
	// Cancel ongoing work on Ctrl+C or SIGTERM.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	// Load connection settings for discovery and shard access.
	hostConfig, err := clientcmd.BuildConfigFromFlags("", *hosting)
	if err != nil {
		return err
	}
	hostConfig.Timeout = 30 * time.Second
	hostClient, err := kubernetes.NewForConfig(hostConfig)
	if err != nil {
		return err
	}
	kcpConfig, err := clientcmd.BuildConfigFromFlags("", *kcp)
	if err != nil {
		return err
	}
	kcpConfig.Timeout = 30 * time.Second
	// Discover shard endpoints.
	services, err := hostClient.CoreV1().Services(*namespace).List(ctx, metav1.ListOptions{
		LabelSelector: "app.kubernetes.io/managed-by=kcp-operator,app.kubernetes.io/component in (rootshard,shard)",
	})
	if err != nil {
		return fmt.Errorf("discover shards: %w", err)
	}
	var shards []shard
	var rootConfig *rest.Config
	names := map[string]bool{}
	for _, service := range services.Items {
		if !hasHTTPS(service) {
			continue
		}
		name := service.Labels["app.kubernetes.io/instance"]
		if name == "" || names[name] {
			return fmt.Errorf("missing or duplicate shard name on service %s", service.Name)
		}
		names[name] = true
		// Open a separate connection for each shard.
		config := rest.CopyConfig(kcpConfig)
		host, closeForward, err := forward(ctx, *hosting, *namespace, service.Name)
		if err != nil {
			return err
		}
		// Keep the connection open until run returns.
		defer closeForward()
		config.Host = host
		// Verify TLS using the original server name.
		config.TLSClientConfig.ServerName = service.Name + "." + *namespace + ".svc.cluster.local"
		shards = append(shards, shard{Name: name, Service: service.Name, Config: config})
		if service.Labels["app.kubernetes.io/component"] == "rootshard" {
			if rootConfig != nil {
				return fmt.Errorf("multiple root shards discovered; select a namespace containing one KCP installation")
			}
			// Save the root connection for migration requests.
			rootConfig = rest.CopyConfig(config)
			rootConfig.Host += "/clusters/root"
		}
	}
	if len(shards) == 0 || rootConfig == nil {
		return fmt.Errorf("no shards or no root shard discovered")
	}
	sort.Slice(shards, func(i, j int) bool { return shards[i].Name < shards[j].Name })
	// Read current placement and calculate moves.
	inventory, err := inventorySnapshot(ctx, shards)
	if err != nil {
		return err
	}
	moves := plan(inventory)
	// Print current counts, target counts, and proposed moves.
	fmt.Println("SHARD\tCURRENT\tPLANNED")
	for _, s := range shards {
		target := len(inventory[s.Name])
		for _, m := range moves {
			if m.From == s.Name {
				target--
			}
			if m.To == s.Name {
				target++
			}
		}
		fmt.Printf("%s\t%d\t%d\n", s.Name, len(inventory[s.Name]), target)
	}
	for _, m := range moves {
		fmt.Printf("MOVE %s (%s): %s -> %s\n", m.Workspace.Path, m.Workspace.Cluster, m.From, m.To)
	}
	// Stop here unless execution was requested.
	if !*apply {
		fmt.Printf("Dry-run: %d migrations planned; no resources changed. Use --apply to execute.\n", len(moves))
		return nil
	}
	client, err := dynamic.NewForConfig(rootConfig)
	if err != nil {
		return err
	}
	resource := client.Resource(migrationGVR)
	// Refuse to start while another migration in root is active.
	existing, err := resource.List(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("list migrations in root (bind migration.kcp.io first): %w", err)
	}
	for _, migration := range existing.Items {
		phase, _, _ := unstructured.NestedString(migration.Object, "status", "phase")
		if phase != "Completed" && phase != "Failed" {
			return fmt.Errorf("migration %s is still active (phase %q); refusing to rebalance", migration.GetName(), phase)
		}
	}
	for _, m := range moves {
		// Stop if placement changed unexpectedly.
		current, err := inventorySnapshot(ctx, shards)
		if err != nil {
			return err
		}
		if !sameInventory(inventory, current) {
			return fmt.Errorf("placement changed since planning; rerun to compute a new plan")
		}
		// Wait for one migration to complete before submitting the next.
		if err := migrate(ctx, resource, m, *timeout); err != nil {
			return err
		}
		// Update expected placement after the completed move.
		for i, w := range inventory[m.From] {
			if w.Cluster == m.Workspace.Cluster {
				inventory[m.From] = append(inventory[m.From][:i], inventory[m.From][i+1:]...)
				break
			}
		}
		inventory[m.To] = append(inventory[m.To], m.Workspace)
	}
	// Confirm placement matches the plan and counts are balanced.
	final, err := inventorySnapshot(ctx, shards)
	if err != nil {
		return err
	}
	if !sameInventory(inventory, final) || len(plan(final)) != 0 {
		return fmt.Errorf("final placement does not match the balanced plan; inspect the cluster")
	}
	fmt.Println("Verified: shard workspace counts differ by at most one.")
	return nil
}

// migrate submits one move and waits for completion.
// A submitted move can continue after this function returns an error.
func migrate(ctx context.Context, resource dynamic.ResourceInterface, m move, timeout time.Duration) error {
	// Build the migration request.
	obj := &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "migration.kcp.io/v1alpha1", "kind": "LogicalClusterMigration",
		"metadata": map[string]interface{}{"generateName": "rebalance-"},
		"spec":     map[string]interface{}{"logicalCluster": m.Workspace.Cluster, "destinationShard": m.To},
	}}
	created, err := resource.Create(ctx, obj, metav1.CreateOptions{})
	if err != nil {
		return fmt.Errorf("create migration for %s: %w", m.Workspace.Path, err)
	}
	fmt.Printf("Created %s for %s\n", created.GetName(), m.Workspace.Path)
	// Check immediately, then every two seconds; API errors stop polling.
	err = wait.PollUntilContextTimeout(ctx, 2*time.Second, timeout, true, func(ctx context.Context) (bool, error) {
		status, err := resource.Get(ctx, created.GetName(), metav1.GetOptions{})
		if err != nil {
			return false, err
		}
		phase, _, _ := unstructured.NestedString(status.Object, "status", "phase")
		if phase == "Failed" {
			return false, fmt.Errorf("migration failed: %v", status.Object["status"])
		}
		return phase == "Completed", nil
	})
	if err != nil {
		return fmt.Errorf("waiting for %s: %w; migration may still be running, inspect before retrying", created.GetName(), err)
	}
	return nil
}

// hasHTTPS checks for the expected HTTPS port.
func hasHTTPS(service corev1.Service) bool {
	for _, port := range service.Spec.Ports {
		if port.Name == "https" && port.Port == 6443 {
			return true
		}
	}
	return false
}

// inventorySnapshot maps each shard name to its non-system workspaces.
// Requests are sequential, not an atomic snapshot.
func inventorySnapshot(ctx context.Context, shards []shard) (map[string][]workspace, error) {
	result := make(map[string][]workspace)
	// Detect duplicate identities across shards.
	seen := map[string]bool{}
	for _, shard := range shards {
		client, err := rest.HTTPClientFor(shard.Config)
		if err != nil {
			return nil, err
		}
		// Fetch this shard's inventory.
		req, err := http.NewRequestWithContext(ctx, http.MethodGet,
			shard.Config.Host+"/clusters/*/apis/core.kcp.io/v1alpha1/logicalclusters", nil)
		if err != nil {
			return nil, err
		}
		resp, err := client.Do(req)
		if err != nil {
			return nil, fmt.Errorf("inventory %s: %w", shard.Name, err)
		}
		list, err := readClusters(resp)
		if err != nil {
			return nil, fmt.Errorf("inventory %s: %w", shard.Name, err)
		}
		// Keep empty shards available as destinations.
		result[shard.Name] = []workspace{}
		for _, obj := range list.Items {
			a := obj.GetAnnotations()
			cluster := a["kcp.io/cluster"]
			// Exclude system entries.
			if cluster == "root" || strings.HasPrefix(cluster, "system:") {
				continue
			}
			// Reject incomplete or non-ready entries.
			path := a["kcp.io/path"]
			phase, _, _ := unstructured.NestedString(obj.Object, "status", "phase")
			if cluster == "" || !strings.HasPrefix(path, "root:") || phase != "Ready" {
				return nil, fmt.Errorf("cluster %q on %s has missing workspace path or non-Ready phase %q", cluster, shard.Name, phase)
			}
			if seen[cluster] {
				return nil, fmt.Errorf("cluster %s appears on multiple shards; migration may be active", cluster)
			}
			seen[cluster] = true
			result[shard.Name] = append(result[shard.Name], workspace{cluster, path})
		}
	}
	return result, nil
}

// readClusters validates the response, decodes JSON, and closes the body.
func readClusters(resp *http.Response) (*unstructured.UnstructuredList, error) {
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		// Limit error response output.
		body, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
		if err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("HTTP %s: %s", resp.Status, body)
	}
	var list unstructured.UnstructuredList
	if err := json.NewDecoder(resp.Body).Decode(&list); err != nil {
		return nil, err
	}
	if list.GetKind() != "LogicalClusterList" {
		return nil, fmt.Errorf("expected LogicalClusterList, got %q", list.GetKind())
	}
	return &list, nil
}

// plan calculates moves until counts differ by at most one, without changing input.
func plan(input map[string][]workspace) []move {
	names := make([]string, 0, len(input))
	counts := map[string]int{}
	candidates := map[string][]workspace{}
	for name, workspaces := range input {
		names = append(names, name)
		counts[name] = len(workspaces)
		// Copy candidates to preserve the input.
		candidates[name] = append([]workspace(nil), workspaces...)
		sort.Slice(candidates[name], func(i, j int) bool {
			return candidates[name][i].Cluster < candidates[name][j].Cluster
		})
	}
	// Sort for deterministic selection.
	sort.Strings(names)
	var moves []move
	if len(names) == 0 {
		return moves
	}
	for {
		// Find the fullest and emptiest shards.
		from, to := names[0], names[0]
		for _, name := range names {
			if counts[name] > counts[from] {
				from = name
			}
			if counts[name] < counts[to] {
				to = name
			}
		}
		// Counts differing by one are balanced.
		if counts[from]-counts[to] <= 1 {
			return moves
		}
		// Record the move and update simulated counts.
		w := candidates[from][0]
		candidates[from] = candidates[from][1:]
		moves = append(moves, move{w, from, to})
		counts[from]--
		counts[to]++
	}
}

// sameInventory compares placement and workspace values, ignoring order.
func sameInventory(a, b map[string][]workspace) bool {
	if len(a) != len(b) {
		return false
	}
	for name, items := range a {
		other, exists := b[name]
		if !exists || len(items) != len(other) {
			return false
		}
		// Compare membership using a set.
		clusters := map[workspace]bool{}
		for _, w := range items {
			clusters[w] = true
		}
		for _, w := range other {
			if !clusters[w] {
				return false
			}
		}
	}
	return true
}

// forward opens a local tunnel and returns its address and required cleanup function.
func forward(ctx context.Context, kubeconfig, namespace, service string) (string, func(), error) {
	ctx, cancel := context.WithCancel(ctx)
	cmd := exec.CommandContext(ctx, "kubectl", "--kubeconfig="+kubeconfig, "-n", namespace,
		"port-forward", "--address=127.0.0.1", "svc/"+service, ":6443")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		cancel()
		return "", nil, err
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		cancel()
		return "", nil, err
	}
	// Channels report readiness and reader completion.
	ready := make(chan string, 1)
	scanned := make(chan struct{})
	// Read process output concurrently.
	go func() {
		defer close(scanned)
		scanner := bufio.NewScanner(stdout)
		re := regexp.MustCompile(`^Forwarding from 127\.0\.0\.1:([0-9]+) -> 6443$`)
		// Extract the port and keep draining output.
		for scanner.Scan() {
			if match := re.FindStringSubmatch(scanner.Text()); match != nil {
				select {
				case ready <- "https://127.0.0.1:" + match[1]:
				default:
				}
			}
		}
		if err := scanner.Err(); err != nil && ctx.Err() == nil {
			fmt.Fprintln(os.Stderr, "port-forward output:", err)
		}
	}()
	// Stop the child process and wait for the reader.
	closeForward := func() {
		cancel()
		<-scanned
		if err := cmd.Wait(); err != nil && ctx.Err() == nil {
			fmt.Fprintln(os.Stderr, "port-forward:", err)
		}
	}
	timer := time.NewTimer(30 * time.Second)
	defer timer.Stop()
	// Wait for readiness, failure, timeout, or cancellation.
	select {
	case host := <-ready:
		return host, closeForward, nil
	case <-scanned:
		closeForward()
		return "", nil, fmt.Errorf("port-forward exited for %s", service)
	case <-timer.C:
		closeForward()
		return "", nil, fmt.Errorf("port-forward readiness timeout for %s", service)
	case <-ctx.Done():
		closeForward()
		return "", nil, ctx.Err()
	}
}
