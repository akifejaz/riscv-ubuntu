# Makefile for RISC-V QEMU Docker Environment
# Provides convenient commands for building, testing, and managing the Docker image

# Configuration
DOCKER_IMAGE ?= riscv-qemu-ubuntu
DOCKER_TAG ?= latest
DOCKER_REGISTRY ?= docker.io
DOCKER_USERNAME ?= cloudv10x
FULL_IMAGE_NAME = $(DOCKER_REGISTRY)/$(DOCKER_USERNAME)/$(DOCKER_IMAGE):$(DOCKER_TAG)

# Build arguments
BUILD_ARGS ?= --progress=plain
DOCKER_BUILDKIT ?= 1

# Test configuration
TEST_CONTAINER_NAME = riscv-container
TEST_RESULTS_DIR = $(PWD)/test-results
LOG_DIR = $(PWD)/logs

# Colors for output
RED = \033[0;31m
GREEN = \033[0;32m
YELLOW = \033[1;33m
BLUE = \033[0;34m
NC = \033[0m

.PHONY: help build test clean push pull run shell logs stop health check-deps

# Default target
.DEFAULT_GOAL := help

## Help target
help: ## Show this help message
	@echo "RISC-V QEMU Docker Environment"
	@echo "==============================="
	@echo ""
	@echo "Available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(BLUE)%-15s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo "Configuration:"
	@echo "  DOCKER_IMAGE:     $(DOCKER_IMAGE)"
	@echo "  DOCKER_TAG:       $(DOCKER_TAG)"
	@echo "  DOCKER_REGISTRY:  $(DOCKER_REGISTRY)"
	@echo "  DOCKER_USERNAME:  $(DOCKER_USERNAME)"
	@echo "  FULL_IMAGE_NAME:  $(FULL_IMAGE_NAME)"
	@echo ""

## Build the Docker image
build: check-deps ## Build the Docker image
	@echo "$(GREEN)Building Docker image: $(FULL_IMAGE_NAME)$(NC)"
	DOCKER_BUILDKIT=$(DOCKER_BUILDKIT) docker build \
		$(BUILD_ARGS) \
		-t $(DOCKER_IMAGE):$(DOCKER_TAG) \
		-t $(FULL_IMAGE_NAME) \
		.
	@echo "$(GREEN)Build completed successfully$(NC)"

## Build without cache
build-no-cache: check-deps ## Build the Docker image without cache
	@echo "$(GREEN)Building Docker image without cache: $(FULL_IMAGE_NAME)$(NC)"
	DOCKER_BUILDKIT=$(DOCKER_BUILDKIT) docker build \
		$(BUILD_ARGS) \
		--no-cache \
		-t $(DOCKER_IMAGE):$(DOCKER_TAG) \
		-t $(FULL_IMAGE_NAME) \
		.
	@echo "$(GREEN)Build completed successfully$(NC)"

## Run quick tests
test-quick: ## Run quick tests (no VM boot)
	@echo "$(GREEN)Running quick tests...$(NC)"
	@./examples/local-test.sh --skip-build --quick-test

## Run full test suite
test: ## Run full test suite
	@echo "$(GREEN)Running full test suite...$(NC)"
	@./examples/local-test.sh --skip-build --full-test

## Run performance tests
test-performance: ## Run performance benchmarks
	@echo "$(GREEN)Running performance tests...$(NC)"
	@./examples/local-test.sh --skip-build --performance-test

## Build and test
build-and-test: build test ## Build image and run tests

## Clean up containers and images
clean: ## Clean up test containers and images
	@echo "$(YELLOW)Cleaning up containers and images...$(NC)"
	-docker stop $(TEST_CONTAINER_NAME) 2>/dev/null || true
	-docker rm $(TEST_CONTAINER_NAME) 2>/dev/null || true
	-docker rmi $(DOCKER_IMAGE):$(DOCKER_TAG) 2>/dev/null || true
	-docker rmi $(FULL_IMAGE_NAME) 2>/dev/null || true
	-docker image prune -f 2>/dev/null || true
	-rm -rf $(TEST_RESULTS_DIR) $(LOG_DIR)
	@echo "$(GREEN)Cleanup completed$(NC)"

## Clean everything including volumes
clean-all: clean ## Clean everything including volumes and networks
	@echo "$(YELLOW)Cleaning all Docker resources...$(NC)"
	-docker system prune -af 2>/dev/null || true
	-docker volume prune -f 2>/dev/null || true
	-docker network prune -f 2>/dev/null || true
	@echo "$(GREEN)Complete cleanup finished$(NC)"

## Push image to registry
push: ## Push image to Docker registry
	@echo "$(GREEN)Pushing image to registry: $(FULL_IMAGE_NAME)$(NC)"
	docker push $(FULL_IMAGE_NAME)
	@echo "$(GREEN)Push completed$(NC)"

## Pull image from registry
pull: ## Pull image from Docker registry
	@echo "$(GREEN)Pulling image from registry: $(FULL_IMAGE_NAME)$(NC)"
	docker pull $(FULL_IMAGE_NAME)
	@echo "$(GREEN)Pull completed$(NC)"

## Run container interactively
run: ## Run container in interactive mode
	@echo "$(GREEN)Starting interactive container...$(NC)"
	docker run -it --rm \
		--name $(TEST_CONTAINER_NAME) \
		--privileged \
		-v $(PWD):/workspace \
		# No default host port mapping; SSH host forwarding is opt-in via SSH_HOST_PORT
		$(DOCKER_IMAGE):$(DOCKER_TAG)

## Run container in background
run-detached: ## Run container in detached mode
	@echo "$(GREEN)Starting detached container...$(NC)"
	docker run -d \
		--name $(TEST_CONTAINER_NAME) \
		--privileged \
		-v $(PWD):/workspace \
		# No default host port mapping; SSH host forwarding is opt-in via SSH_HOST_PORT
		$(DOCKER_IMAGE):$(DOCKER_TAG) \
		shell
	@echo "$(GREEN)Container started: $(TEST_CONTAINER_NAME)$(NC)"
	@echo "Access via: docker exec -it $(TEST_CONTAINER_NAME) bash"

## Get shell access to running container
shell: ## Get shell access to running container
	@echo "$(GREEN)Connecting to container shell...$(NC)"
	docker exec -it $(TEST_CONTAINER_NAME) bash

## View container logs
logs: ## View container logs
	@echo "$(GREEN)Showing container logs...$(NC)"
	docker logs -f $(TEST_CONTAINER_NAME)

## Stop running container
stop: ## Stop running container
	@echo "$(YELLOW)Stopping container: $(TEST_CONTAINER_NAME)$(NC)"
	-docker stop $(TEST_CONTAINER_NAME)
	@echo "$(GREEN)Container stopped$(NC)"

## Check container health
health: ## Check container health status
	@echo "$(GREEN)Checking container health...$(NC)"
	@if docker ps --filter name=$(TEST_CONTAINER_NAME) --format "table {{.Names}}\t{{.Status}}" | grep -q $(TEST_CONTAINER_NAME); then \
		echo "Container is running"; \
		docker exec $(TEST_CONTAINER_NAME) /opt/scripts/health-check.sh; \
	else \
		echo "$(RED)Container $(TEST_CONTAINER_NAME) is not running$(NC)"; \
		exit 1; \
	fi

## Show image information
info: ## Show image information and size
	@echo "$(GREEN)Docker image information:$(NC)"
	@docker images $(DOCKER_IMAGE):$(DOCKER_TAG) --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
	@echo ""
	@echo "$(GREEN)Image layers:$(NC)"
	@docker history $(DOCKER_IMAGE):$(DOCKER_TAG) --format "table {{.CreatedBy}}\t{{.Size}}" --no-trunc

## Start with docker-compose
compose-up: ## Start services with docker-compose
	@echo "$(GREEN)Starting services with docker-compose...$(NC)"
	docker-compose up -d
	@echo "$(GREEN)Services started$(NC)"

## Stop docker-compose services
compose-down: ## Stop docker-compose services
	@echo "$(YELLOW)Stopping docker-compose services...$(NC)"
	docker-compose down
	@echo "$(GREEN)Services stopped$(NC)"

## View docker-compose logs
compose-logs: ## View docker-compose logs
	@echo "$(GREEN)Showing docker-compose logs...$(NC)"
	docker-compose logs -f

## Run CI tests
ci-test: ## Run tests suitable for CI environment
	@echo "$(GREEN)Running CI tests...$(NC)"
	docker run --rm \
		--privileged \
		-e RISCV_MEMORY=2G \
		-e RISCV_CPUS=1 \
		-e BOOT_TIMEOUT=180 \
		$(DOCKER_IMAGE):$(DOCKER_TAG) \
		test system network

## Security scan with Trivy
security-scan: ## Run security scan on the image
	@echo "$(GREEN)Running security scan...$(NC)"
	@if command -v trivy >/dev/null 2>&1; then \
		trivy image --exit-code 0 --no-progress --format table $(DOCKER_IMAGE):$(DOCKER_TAG); \
	else \
		echo "$(YELLOW)Trivy not installed, running with Docker...$(NC)"; \
		docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
			aquasec/trivy:latest image --exit-code 0 --no-progress --format table $(DOCKER_IMAGE):$(DOCKER_TAG); \
	fi

## Check dependencies
check-deps: ## Check required dependencies
	@echo "$(GREEN)Checking dependencies...$(NC)"
	@command -v docker >/dev/null 2>&1 || { echo "$(RED)Docker is required but not installed$(NC)"; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "$(RED)Cannot connect to Docker daemon$(NC)"; exit 1; }
	@echo "$(GREEN)Dependencies OK$(NC)"

## Development setup
dev-setup: ## Set up development environment
	@echo "$(GREEN)Setting up development environment...$(NC)"
	@mkdir -p $(TEST_RESULTS_DIR) $(LOG_DIR)
	@chmod +x scripts/*.sh examples/*.sh
	@echo "$(GREEN)Development environment ready$(NC)"

## Lint Dockerfiles
lint: ## Lint Dockerfile and scripts
	@echo "$(GREEN)Linting files...$(NC)"
	@if command -v hadolint >/dev/null 2>&1; then \
		hadolint Dockerfile; \
	else \
		echo "$(YELLOW)hadolint not installed, skipping Dockerfile linting$(NC)"; \
	fi
	@if command -v shellcheck >/dev/null 2>&1; then \
		find scripts/ -name "*.sh" -exec shellcheck {} \; || true; \
	else \
		echo "$(YELLOW)shellcheck not installed, skipping shell script linting$(NC)"; \
	fi

## Show resource usage
stats: ## Show container resource usage
	@echo "$(GREEN)Container resource usage:$(NC)"
	@docker stats $(TEST_CONTAINER_NAME) --no-stream 2>/dev/null || echo "Container not running"

## Export image
export: ## Export image to tar file
	@echo "$(GREEN)Exporting image to tar file...$(NC)"
	docker save $(DOCKER_IMAGE):$(DOCKER_TAG) | gzip > $(DOCKER_IMAGE)-$(DOCKER_TAG).tar.gz
	@echo "$(GREEN)Image exported to $(DOCKER_IMAGE)-$(DOCKER_TAG).tar.gz$(NC)"

## Import image
import: ## Import image from tar file
	@echo "$(GREEN)Importing image from tar file...$(NC)"
	@if [ -f "$(DOCKER_IMAGE)-$(DOCKER_TAG).tar.gz" ]; then \
		gunzip -c $(DOCKER_IMAGE)-$(DOCKER_TAG).tar.gz | docker load; \
		echo "$(GREEN)Image imported successfully$(NC)"; \
	else \
		echo "$(RED)Tar file not found: $(DOCKER_IMAGE)-$(DOCKER_TAG).tar.gz$(NC)"; \
		exit 1; \
	fi