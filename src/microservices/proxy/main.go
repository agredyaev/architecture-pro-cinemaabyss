package main

import (
	"context"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type Config struct {
	Port                   string
	MonolithURL            *url.URL
	MoviesServiceURL       *url.URL
	EventsServiceURL       *url.URL
	GradualMigration       bool
	MoviesMigrationPercent int
}

// loadConfig loads configuration from environment variables.
func loadConfig() (*Config, error) {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8000"
	}

	parseURL := func(env, name string) (*url.URL, error) {
		raw := os.Getenv(env)
		if raw == "" {
			return nil, fmt.Errorf("%s environment variable not set", env)
		}
		u, err := url.Parse(raw)
		if err != nil {
			return nil, fmt.Errorf("invalid %s: %w", env, err)
		}
		return u, nil
	}

	monolithURL, err := parseURL("MONOLITH_URL", "MONOLITH_URL")
	if err != nil {
		return nil, err
	}
	moviesServiceURL, err := parseURL("MOVIES_SERVICE_URL", "MOVIES_SERVICE_URL")
	if err != nil {
		return nil, err
	}
	eventsServiceURL, err := parseURL("EVENTS_SERVICE_URL", "EVENTS_SERVICE_URL")
	if err != nil {
		log.Printf("Warning: %v (events routing disabled)", err)
		eventsServiceURL = nil // Set to nil to avoid using an invalid URL
	}

	gradualMigration := strings.EqualFold(os.Getenv("GRADUAL_MIGRATION"), "true")

	moviesMigrationPercent := 0
	if s := os.Getenv("MOVIES_MIGRATION_PERCENT"); s != "" {
		if v, err := strconv.Atoi(s); err == nil {
			moviesMigrationPercent = v
		} else {
			log.Printf("Warning: invalid MOVIES_MIGRATION_PERCENT, using 0: %v", err)
		}
	}
	if moviesMigrationPercent < 0 {
		moviesMigrationPercent = 0
	}
	if moviesMigrationPercent > 100 {
		moviesMigrationPercent = 100
	}

	return &Config{
		Port:                   port,
		MonolithURL:            monolithURL,
		MoviesServiceURL:       moviesServiceURL,
		EventsServiceURL:       eventsServiceURL,
		GradualMigration:       gradualMigration,
		MoviesMigrationPercent: moviesMigrationPercent,
	}, nil
}

// newProxy creates a new reverse proxy with proper Director and headers.
func newProxy(target *url.URL) *httputil.ReverseProxy {
	rp := httputil.NewSingleHostReverseProxy(target)
	origDirector := rp.Director
	rp.Director = func(req *http.Request) {
		origDirector(req)
		req.Host = target.Host
		req.Header.Set("X-Forwarded-Host", req.Host)
		req.Header.Set("X-Forwarded-Proto", "http")
		if req.TLS != nil {
			req.Header.Set("X-Forwarded-Proto", "https")
		}
		req.Header.Set("X-Forwarded-For", clientIP(req))
	}
	// Configure transport with connection timeouts
	rp.Transport = &http.Transport{
		MaxIdleConns:        100,
		IdleConnTimeout:     90 * time.Second,
		DisableCompression:  false,
		ForceAttemptHTTP2:   true,
		TLSHandshakeTimeout: 10 * time.Second,
	}
	// Upstream error logging
	rp.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log.Printf("proxy error for %s %s: %v", r.Method, r.URL.String(), err)
		http.Error(w, "upstream error", http.StatusBadGateway)
	}
	return rp
}

// clientIP extracts the client's IP address from the request.
func clientIP(r *http.Request) string {
	ip := r.Header.Get("X-Real-IP")
	if ip != "" {
		return ip
	}
	host := r.RemoteAddr
	if i := strings.LastIndex(host, ":"); i != -1 {
		return host[:i]
	}
	return host
}

type proxyHandler struct {
	config             *Config
	monolithProxy      *httputil.ReverseProxy
	moviesServiceProxy *httputil.ReverseProxy
	eventsServiceProxy *httputil.ReverseProxy
	rng                *rand.Rand
}

// newProxyHandler creates a new proxyHandler instance.
func newProxyHandler(cfg *Config) *proxyHandler {
	ph := &proxyHandler{
		config:             cfg,
		monolithProxy:      newProxy(cfg.MonolithURL),
		moviesServiceProxy: newProxy(cfg.MoviesServiceURL),
		rng:                rand.New(rand.NewSource(time.Now().UnixNano())),
	}
	if cfg.EventsServiceURL != nil {
		ph.eventsServiceProxy = newProxy(cfg.EventsServiceURL)
	}
	return ph
}

// ServeHTTP implements the http.Handler interface.
func (p *proxyHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	path := r.URL.Path

	// Access log
	defer func() {
		log.Printf("%s %s %dms", r.Method, path, time.Since(start).Milliseconds())
	}()

	// Route /api/movies requests
	if strings.HasPrefix(path, "/api/movies") {
		if p.config.GradualMigration {
			roll := p.rng.Intn(100) // 0..99
			if roll < p.config.MoviesMigrationPercent {
				log.Printf("Routing /api/movies request to Movies Service (roll %d < %d)", roll, p.config.MoviesMigrationPercent)
				p.moviesServiceProxy.ServeHTTP(w, r)
				return
			}
			log.Printf("Routing /api/movies request to Monolith (roll %d >= %d)", roll, p.config.MoviesMigrationPercent)
			p.monolithProxy.ServeHTTP(w, r)
			return
		}
		log.Printf("Routing /api/movies request to Movies Service (100%% migration disabled)")
		p.moviesServiceProxy.ServeHTTP(w, r)
		return
	}

	// Route /api/events requests if Events Service is configured
	if p.config.EventsServiceURL != nil && strings.HasPrefix(path, "/api/events") {
		log.Printf("Routing /api/events request to Events Service")
		p.eventsServiceProxy.ServeHTTP(w, r)
		return
	}

	// Default route to Monolith
	log.Printf("Routing %s request to Monolith (default)", r.URL.Path)
	p.monolithProxy.ServeHTTP(w, r)
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	handler := newProxyHandler(cfg)

	server := &http.Server{
		Addr:         ":" + cfg.Port,
		Handler:      handler,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	log.Printf("proxy on :%s", cfg.Port)
	log.Printf("monolith: %s", cfg.MonolithURL)
	log.Printf("movies  : %s", cfg.MoviesServiceURL)
	if cfg.EventsServiceURL != nil {
		log.Printf("events  : %s", cfg.EventsServiceURL)
	}
	log.Printf("gradual : %t, movies %%: %d", cfg.GradualMigration, cfg.MoviesMigrationPercent)

	// Graceful shutdown
	go func() {
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server: %v", err)
		}
	}()
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	log.Println("Shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = server.Shutdown(ctx)
	log.Println("Stopped")
}
