# BlakTail developer targets. See README.md.
.PHONY: up down logs agent rust

up:
	./scripts/quickstart.sh

down:
	docker compose down

logs:
	docker compose logs -f --tail=100

agent:
	cargo build --locked --release -p blaktaild -p blaktail-config

rust:
	cargo build --locked --workspace
