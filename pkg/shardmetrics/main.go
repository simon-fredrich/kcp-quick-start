package main

import (
	"context"
	"fmt"
	"time"

	promapi "github.com/prometheus/client_golang/api"
	promv1 "github.com/prometheus/client_golang/api/prometheus/v1"
)

func main() {
	promConfig := promapi.Config{
		Address: "http://localhost:9090",
	}

	promClient, err := promapi.NewClient(promConfig)
	if err != nil {
		panic(err)
	}

	prom := promv1.NewAPI(promClient)

	podCPU, myWarningsCPU, myInfosCPU, err := prom.Query(
		context.Background(),
		`
    sum by (pod) (
        rate(container_cpu_usage_seconds_total{
            namespace="default",
            pod!="",
            container!="",
            container!="POD"
        }[5m])
    ) * 1000
`,
		time.Now(),
	)
	if err != nil {
		panic(err)
	}

	podMemory, myWarningsMemory, myInfosMemory, err := prom.Query(
		context.Background(),
		`
    sum by (pod) (
        container_memory_working_set_bytes{
            namespace="default",
            pod!="",
            container!="",
            container!="POD"
        }
    ) / 1024 / 1024
`,
		time.Now(),
	)
	if err != nil {
		panic(err)
	}

	fmt.Printf("Pod CPU:\n%s,\nWarnings: %s, Infos: %s\n\n", podCPU, myWarningsMemory, myInfosMemory)

	fmt.Printf("Pod Memory:\n%s,\nWarnings: %s, Infos: %s", podMemory, myWarningsCPU, myInfosCPU)
}
