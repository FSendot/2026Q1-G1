package main

import (
	"context"
	"log"
	"os"

	"github.com/FSendot/fraud-detector/results-writer/internal/writer"
)

func main() {
	dbCfg, err := writer.LoadDBConfigFromEnv()
	if err != nil {
		log.Fatalf("load db config: %v", err)
	}

	db, err := writer.OpenDB(dbCfg)
	if err != nil {
		log.Fatalf("open db: %v", err)
	}
	defer db.Close()

	runtime, err := writer.NewRuntime(db, log.New(os.Stderr, "", 0))
	if err != nil {
		log.Fatalf("init runtime: %v", err)
	}

	if err := runtime.Serve(context.Background()); err != nil {
		log.Fatalf("runtime stopped: %v", err)
	}
}
