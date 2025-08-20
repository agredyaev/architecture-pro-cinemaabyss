package main

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/segmentio/kafka-go"
)

type EventHandler struct {
	writer      *kafka.Writer
	allowed     map[string]struct{}
	maxBodySize int64
}

func NewEventHandler(broker string, topics []string) *EventHandler {
	allow := make(map[string]struct{}, len(topics))
	for _, t := range topics {
		allow[t] = struct{}{}
	}
	w := &kafka.Writer{
		Addr:         kafka.TCP(broker),
		Balancer:     &kafka.LeastBytes{},
		RequiredAcks: kafka.RequireOne,
		BatchSize:    100,
		BatchTimeout: 75 * time.Millisecond,
		Async:        false,
	}
	return &EventHandler{
		writer:      w,
		allowed:     allow,
		maxBodySize: 1 << 20, // 1MB
	}
}

func (h *EventHandler) handleEvent(w http.ResponseWriter, r *http.Request, topic string) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "only POST is allowed")
		return
	}
	if _, ok := h.allowed[topic]; !ok {
		writeError(w, http.StatusBadRequest, "unknown topic")
		return
	}
	ct := r.Header.Get("Content-Type")
	if ct != "" && !strings.HasPrefix(ct, "application/json") {
		writeError(w, http.StatusUnsupportedMediaType, "Content-Type must be application/json")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, h.maxBodySize)
	defer r.Body.Close()

	body, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, http.StatusBadRequest, "cannot read body")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	msg := kafka.Message{Topic: topic, Value: body}
	start := time.Now()
	if err := h.writer.WriteMessages(ctx, msg); err != nil {
		log.Printf("kafka write failed topic=%s err=%v", topic, err)
		writeError(w, http.StatusInternalServerError, "failed to publish event")
		return
	}
	lat := time.Since(start).Milliseconds()
	log.Printf("PRODUCER: message sent to topic=%s bytes=%d latency_ms=%d", topic, len(body), lat)

	writeJSON(w, http.StatusCreated, map[string]string{"status": "success"})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("Error writing JSON response: %v", err)
	}
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func consumeEvents(ctx context.Context, wg *sync.WaitGroup, broker, topic string) {
	defer wg.Done()
	r := kafka.NewReader(kafka.ReaderConfig{
		Brokers:  []string{broker},
		Topic:    topic,
		GroupID:  "events-service-consumer",
		MinBytes: 10e3, // 10KB
		MaxBytes: 10e6, // 10MB
	})
	defer r.Close()

	log.Printf("Starting consumer for topic %s", topic)

	for {
		select {
		case <-ctx.Done():
			log.Printf("Shutting down consumer for topic %s", topic)
			return
		default:
			m, err := r.ReadMessage(ctx)
			if err != nil {
				if err == context.Canceled || err == context.DeadlineExceeded {
					return
				}
				log.Printf("Consumer error for topic %s: %v", topic, err)
				continue
			}
			log.Printf("CONSUMER: received message from topic %s: value=%s", m.Topic, string(m.Value))
		}
	}
}

func main() {
	broker := os.Getenv("KAFKA_BROKER_URL")
	if broker == "" {
		broker = "kafka:9092"
	}

	topicMap := map[string]string{
		"/api/events/movie":   "movie-events",
		"/api/events/user":    "user-events",
		"/api/events/payment": "payment-events",
	}
	var topics []string
	for _, topic := range topicMap {
		topics = append(topics, topic)
	}

	handler := NewEventHandler(broker, topics)

	mux := http.NewServeMux()
	for path, topic := range topicMap {
		topic := topic // capture loop variable
		mux.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) {
			handler.handleEvent(w, r, topic)
		})
	}
	mux.HandleFunc("/api/events/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]bool{"status": true})
	})

	srv := &http.Server{
		Addr:         ":8082",
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	// Graceful shutdown context
	shutdownCtx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// Start consumers
	var wg sync.WaitGroup
	for _, topic := range topics {
		wg.Add(1)
		go consumeEvents(shutdownCtx, &wg, broker, topic)
	}

	go func() {
		log.Println("events service listening on :8082")
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("listen: %v", err)
		}
	}()

	<-shutdownCtx.Done()

	log.Println("shutting down...")

	// Shutdown server
	shutdownTimeoutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownTimeoutCtx); err != nil {
		log.Printf("Server shutdown error: %v", err)
	}

	// Wait for consumers to finish
	wg.Wait()

	// Close Kafka writer
	if err := handler.writer.Close(); err != nil {
		log.Printf("Kafka writer close error: %v", err)
	}

	log.Println("stopped")
}
