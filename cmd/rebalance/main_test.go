package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/dynamic/fake"
	"k8s.io/client-go/rest"
	clienttesting "k8s.io/client-go/testing"
)

func TestPlan(t *testing.T) {
	tests := []struct {
		counts []int
		moves  int
	}{
		{[]int{}, 0},
		{[]int{9}, 0},
		{[]int{0, 0, 0}, 0},
		{[]int{3, 3, 3}, 0},
		{[]int{2, 3, 3}, 0},
		{[]int{5, 1, 3}, 2},
		{[]int{9, 0, 0}, 6},
		{[]int{1, 0, 0}, 0},
		{[]int{4, 4, 0, 0}, 4},
	}
	for _, tt := range tests {
		t.Run(fmt.Sprint(tt.counts), func(t *testing.T) {
			input := map[string][]workspace{}
			for shard, count := range tt.counts {
				name := fmt.Sprintf("shard-%d", shard)
				input[name] = []workspace{}
				for i := 0; i < count; i++ {
					id := fmt.Sprintf("%s-cluster-%d", name, i)
					input[name] = append(input[name], workspace{id, "root:" + id})
				}
			}
			moves := plan(input)
			if len(moves) != tt.moves {
				t.Fatalf("got %d moves, want %d", len(moves), tt.moves)
			}
			if !reflect.DeepEqual(moves, plan(input)) {
				t.Fatal("plan is not deterministic")
			}
			counts := map[string]int{}
			seen := map[string]bool{}
			for name, items := range input {
				counts[name] = len(items)
			}
			for _, m := range moves {
				if seen[m.Workspace.Cluster] {
					t.Fatal("workspace moved twice")
				}
				seen[m.Workspace.Cluster] = true
				counts[m.From]--
				counts[m.To]++
			}
			for _, a := range counts {
				for _, b := range counts {
					if a-b > 1 {
						t.Fatalf("not balanced: %v", counts)
					}
				}
			}
			for name, items := range input {
				var index int
				fmt.Sscanf(name, "shard-%d", &index)
				if len(items) != tt.counts[index] {
					t.Fatal("input modified")
				}
			}
		})
	}
}

func TestInventory(t *testing.T) {
	for _, tt := range []struct {
		name, body string
		status     int
		wantErr    bool
	}{
		{"valid", `{"kind":"LogicalClusterList","items":[
			{"metadata":{"annotations":{"kcp.io/cluster":"root"}}},
			{"metadata":{"annotations":{"kcp.io/cluster":"system:shard"}}},
			{"metadata":{"annotations":{"kcp.io/cluster":"abc","kcp.io/path":"root:team"}},"status":{"phase":"Ready"}}]}`, 200, false},
		{"forbidden", `denied`, 403, true},
		{"wrong-kind", `{"kind":"WorkspaceList","items":[]}`, 200, true},
		{"not-ready", `{"kind":"LogicalClusterList","items":[{"metadata":{"annotations":{"kcp.io/cluster":"abc","kcp.io/path":"root:team"}},"status":{"phase":"Scheduling"}}]}`, 200, true},
		{"missing-path", `{"kind":"LogicalClusterList","items":[{"metadata":{"annotations":{"kcp.io/cluster":"abc"}},"status":{"phase":"Ready"}}]}`, 200, true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/clusters/*/apis/core.kcp.io/v1alpha1/logicalclusters" {
					t.Errorf("unexpected path %s", r.URL.Path)
				}
				w.WriteHeader(tt.status)
				fmt.Fprint(w, tt.body)
			}))
			defer server.Close()
			result, err := inventorySnapshot(context.Background(), []shard{{Name: "one", Config: &rest.Config{Host: server.URL}}})
			if (err != nil) != tt.wantErr {
				t.Fatalf("unexpected error: %v", err)
			}
			if !tt.wantErr && len(result["one"]) != 1 {
				t.Fatalf("expected one non-system workspace: %v", result)
			}
			if !tt.wantErr {
				_, err := inventorySnapshot(context.Background(), []shard{
					{Name: "one", Config: &rest.Config{Host: server.URL}},
					{Name: "two", Config: &rest.Config{Host: server.URL}},
				})
				if err == nil || !strings.Contains(err.Error(), "multiple shards") {
					t.Fatalf("expected duplicate placement error, got %v", err)
				}
			}
		})
	}
}

func TestSameInventory(t *testing.T) {
	a := map[string][]workspace{"a": {{"one", "root:one"}, {"two", "root:two"}}, "b": {}}
	b := map[string][]workspace{"a": {{"two", "root:two"}, {"one", "root:one"}}, "b": {}}
	if !sameInventory(a, b) {
		t.Fatal("ordering should not affect comparison")
	}

	b["a"] = b["a"][:1]
	b["b"] = []workspace{{"one", "root:one"}}
	if sameInventory(a, b) {
		t.Fatal("placement change was not detected")
	}
}

func TestMigrate(t *testing.T) {
	for _, phase := range []string{"Completed", "Failed", "Preparing"} {
		t.Run(phase, func(t *testing.T) {
			client := fake.NewSimpleDynamicClient(runtime.NewScheme())
			client.PrependReactor("create", "logicalclustermigrations", func(action clienttesting.Action) (bool, runtime.Object, error) {
				obj := action.(clienttesting.CreateAction).GetObject().(*unstructured.Unstructured)
				if obj.Object["apiVersion"] != "migration.kcp.io/v1alpha1" || obj.GetGenerateName() != "rebalance-" {
					t.Fatalf("unexpected migration: %v", obj)
				}
				cluster, _, _ := unstructured.NestedString(obj.Object, "spec", "logicalCluster")
				destination, _, _ := unstructured.NestedString(obj.Object, "spec", "destinationShard")
				if cluster != "abc" || destination != "two" {
					t.Fatalf("wrong migration spec: %v", obj)
				}
				obj.SetName("rebalance-test")
				return true, obj, nil
			})
			client.PrependReactor("get", "logicalclustermigrations", func(action clienttesting.Action) (bool, runtime.Object, error) {
				if action.(clienttesting.GetAction).GetName() != "rebalance-test" {
					t.Fatal("polling the wrong migration")
				}
				return true, &unstructured.Unstructured{Object: map[string]interface{}{
					"status": map[string]interface{}{"phase": phase},
				}}, nil
			})
			err := migrate(context.Background(), client.Resource(migrationGVR),
				move{workspace{"abc", "root:team"}, "one", "two"}, 10*time.Millisecond)
			if (err == nil) != (phase == "Completed") {
				t.Fatalf("phase %s: %v", phase, err)
			}
			if err != nil && !strings.Contains(err.Error(), "inspect before retrying") {
				t.Fatalf("error should explain recovery: %v", err)
			}
		})
	}
}
