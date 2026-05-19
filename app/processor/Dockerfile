FROM golang:1.26-alpine AS builder

WORKDIR /app/processor

COPY processor/go.mod processor/go.sum ./
COPY net/serving/go ../net/serving/go
RUN go mod download

COPY processor/cmd ./cmd
COPY processor/internal ./internal
RUN CGO_ENABLED=0 go build -o /fraud-worker ./cmd/worker

FROM alpine:3.21

RUN apk add --no-cache ca-certificates

COPY --from=builder /fraud-worker /fraud-worker
RUN mkdir -p /model
COPY processor/model/runtime_spec.json /model/runtime_spec.json

ENV FRAUD_RUNTIME_SPEC_PATH=/model/runtime_spec.json

ENTRYPOINT ["/fraud-worker"]
