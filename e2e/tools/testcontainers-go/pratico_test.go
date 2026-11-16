// Testcontainers against pratico (make e2e-tools): what Go, Java, Node, and Python
// test suites do with Docker every day, here through the same library.
package praticotools

import (
	"context"
	"fmt"
	"net"
	"testing"
	"time"

	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"
)

// start runs an image as Testcontainers does: pull, its reaper (Ryuk, which mounts the
// Docker socket), a published port, and a wait on the log.
func start(t *testing.T, req testcontainers.ContainerRequest) (testcontainers.Container, string) {
	t.Helper()
	ctx := context.Background()
	c, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{ContainerRequest: req, Started: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Terminate(ctx) })
	ep, err := c.Endpoint(ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	return c, ep
}

func TestRedis(t *testing.T) {
	_, ep := start(t, testcontainers.ContainerRequest{
		Image:        "redis:7-alpine",
		ExposedPorts: []string{"6379/tcp"},
		WaitingFor:   wait.ForLog("Ready to accept connections").WithStartupTimeout(60 * time.Second),
	})
	conn, err := net.DialTimeout("tcp", ep, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	fmt.Fprint(conn, "PING\r\n")
	buf := make([]byte, 16)
	n, _ := conn.Read(buf)
	if string(buf[:n]) != "+PONG\r\n" {
		t.Fatalf("redis answered %q", buf[:n])
	}
}

func TestPostgres(t *testing.T) {
	c, _ := start(t, testcontainers.ContainerRequest{
		Image:        "postgres:17-alpine",
		ExposedPorts: []string{"5432/tcp"},
		Env:          map[string]string{"POSTGRES_PASSWORD": "test"},
		WaitingFor:   wait.ForLog("database system is ready to accept connections").WithOccurrence(2).WithStartupTimeout(90 * time.Second),
	})
	code, _, err := c.Exec(context.Background(), []string{"psql", "-U", "postgres", "-tAc", "select 1"})
	if err != nil || code != 0 {
		t.Fatalf("psql: code %d, %v", code, err)
	}
}
