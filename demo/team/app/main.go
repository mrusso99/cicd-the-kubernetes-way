package main

import (
	"fmt"
	"net/http"
	"os"
)

// Tiny service: the point of the demo is the delivery chain, not the app.
func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "hello from the sovereign delivery chain")
	})
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	addr := ":8080"
	if v := os.Getenv("LISTEN_ADDR"); v != "" {
		addr = v
	}
	_ = http.ListenAndServe(addr, nil)
}
