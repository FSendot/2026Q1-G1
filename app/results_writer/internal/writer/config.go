package writer

import (
	"database/sql"
	"fmt"
	"os"
	"strconv"
	"time"

	_ "github.com/lib/pq"
)

type DBConfig struct {
	Host     string
	Port     int
	Name     string
	User     string
	Password string
}

func LoadDBConfigFromEnv() (DBConfig, error) {
	port := 5432
	if rawPort := os.Getenv("DB_PORT"); rawPort != "" {
		parsedPort, err := strconv.Atoi(rawPort)
		if err != nil {
			return DBConfig{}, fmt.Errorf("parse DB_PORT: %w", err)
		}
		port = parsedPort
	}

	return DBConfig{
		Host:     os.Getenv("DB_HOST"),
		Port:     port,
		Name:     valueOrDefault(os.Getenv("DB_NAME"), "fraud_results"),
		User:     valueOrDefault(os.Getenv("DB_USER"), "fraud_admin"),
		Password: os.Getenv("DB_PASSWORD"),
	}, nil
}

func OpenDB(cfg DBConfig) (*sql.DB, error) {
	dsn := fmt.Sprintf(
		"host=%s port=%d dbname=%s user=%s password=%s sslmode=require connect_timeout=5",
		cfg.Host,
		cfg.Port,
		cfg.Name,
		cfg.User,
		cfg.Password,
	)

	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, fmt.Errorf("open postgres: %w", err)
	}

	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(5 * time.Minute)

	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ping postgres: %w", err)
	}

	return db, nil
}

func valueOrDefault(value, fallback string) string {
	if value != "" {
		return value
	}
	return fallback
}
