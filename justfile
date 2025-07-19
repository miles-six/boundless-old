# Variables
DEFAULT_DATABASE_URL := "postgres://postgres:password@localhost:5433/postgres"
DATABASE_URL := env_var_or_default("DATABASE_URL", DEFAULT_DATABASE_URL)

LOGS_DIR := "logs"
PID_FILE := LOGS_DIR + "/localnet.pid"

# Show available commands
default:
    @just --list

# Check that required dependencies are installed
check-deps:
    #!/usr/bin/env bash
    for cmd in forge cargo anvil jq; do
        command -v $cmd >/dev/null 2>&1 || { echo "Error: $cmd is not installed."; exit 1; }
    done

# Run all CI checks
ci: check test

# Run all tests
test: test-foundry test-cargo

# Run Foundry tests
test-foundry:
    forge test -vvv --isolate

# Run all Cargo tests
test-cargo: test-cargo-root test-cargo-example test-cargo-db

# Run Cargo tests for root workspace
test-cargo-root:
    RISC0_DEV_MODE=1 cargo test --workspace --exclude order-stream --exclude boundless-cli -- --include-ignored

# Run Cargo tests for counter example
test-cargo-example:
    cd examples/counter && \
    forge build && \
    RISC0_DEV_MODE=1 cargo test

# Run database tests
test-cargo-db: 
    just test-db setup
    DATABASE_URL={{DATABASE_URL}} RISC0_DEV_MODE=1 cargo test -p order-stream -- --include-ignored
    DATABASE_URL={{DATABASE_URL}} RISC0_DEV_MODE=1 cargo test -p boundless-cli -- --include-ignored
    just test-db clean

# Manage test postgres instance (setup or clean, defaults to setup)
test-db action="setup":
    #!/usr/bin/env bash
    if [ "{{action}}" = "setup" ]; then
        docker inspect postgres-test > /dev/null 2>&1 || \
        docker run -d \
            --name postgres-test \
            -e POSTGRES_PASSWORD=password \
            -p 5433:5432 \
            postgres:latest
        # Wait for PostgreSQL to be ready
        sleep 3
        docker exec -u postgres postgres-test psql -U postgres -c "CREATE DATABASE test_db;"
    elif [ "{{action}}" = "clean" ]; then
        docker stop postgres-test
        docker rm postgres-test
    else
        echo "Unknown action: {{action}}"
        echo "Available actions: setup, clean"
        exit 1
    fi

# Run all formatting and linting checks
check: check-links check-license check-format check-clippy check-docs check-deployments

# Check links in markdown files
check-links:
    @echo "Checking links in markdown files..."
    git ls-files '*.md' ':!:documentation/*' | xargs lychee --base . --cache --

# Check licenses
check-license:
    @python license-check.py

# Check deployments addresses
check-deployments:
    @echo "Checking deployment addresses..."
    @python deployments-check.py

# Check code formatting
check-format:
    cargo sort --workspace --check
    cargo fmt --all --check
    cd examples/counter && cargo sort --workspace --check
    cd examples/counter && cargo fmt --all --check
    cd examples/smart-contract-requestor && cargo sort --workspace --check
    cd examples/smart-contract-requestor && cargo fmt --all --check
    cd examples/composition && cargo sort --workspace --check
    cd examples/composition && cargo fmt --all --check
    cd examples/counter-with-callback && cargo sort --workspace --check
    cd examples/counter-with-callback && cargo fmt --all --check
    cd crates/guest/assessor && cargo sort --workspace --check
    cd crates/guest/assessor && cargo fmt --all --check
    cd crates/guest/util && cargo sort --workspace --check
    cd crates/guest/util && cargo fmt --all --check
    cd documentation && bun run check
    dprint check
    forge fmt --check

# Run Cargo clippy
check-clippy:
    RUSTFLAGS=-Dwarnings RISC0_SKIP_BUILD=1 RISC0_SKIP_BUILD_KERNEL=1 \
    cargo clippy --workspace --all-targets

    cd examples/counter && forge build && \
    RUSTFLAGS=-Dwarnings RISC0_SKIP_BUILD=1 RISC0_SKIP_BUILD_KERNEL=1 \
    cargo clippy --workspace --all-targets

    cd examples/composition && forge build && \
    RUSTFLAGS=-Dwarnings RISC0_SKIP_BUILD=1 RISC0_SKIP_BUILD_KERNEL=1 \
    cargo clippy --workspace --all-targets

    cd examples/counter-with-callback && \
    forge build && \
    RUSTFLAGS=-Dwarnings RISC0_SKIP_BUILD=1 RISC0_SKIP_BUILD_KERNEL=1 \
    cargo clippy --workspace --all-targets

    cd examples/smart-contract-requestor && \
    forge build && \
    RUSTFLAGS=-Dwarnings ISC0_SKIP_BUILD=1 RISC0_SKIP_BUILD_KERNEL=1 \
    cargo clippy --workspace --all-targets

check-docs:
    # Matches the docs-rs job in CI 
    RUSTDOCFLAGS="--cfg docsrs -D warnings" RISC0_SKIP_BUILD=1 cargo +nightly-2025-01-03 doc -p boundless-market --all-features --no-deps

# Format all code
format:
    cargo sort --workspace
    cargo fmt --all
    cd examples/counter && cargo sort --workspace
    cd examples/counter && cargo fmt --all
    cd examples/smart-contract-requestor && cargo sort --workspace
    cd examples/smart-contract-requestor && cargo fmt --all
    cd examples/composition && cargo sort --workspace
    cd examples/composition && cargo fmt --all
    cd examples/counter-with-callback && cargo sort --workspace
    cd examples/counter-with-callback && cargo fmt --all
    cd crates/guest/assessor && cargo sort --workspace
    cd crates/guest/assessor && cargo fmt --all
    cd crates/guest/util && cargo sort --workspace
    cd crates/guest/util && cargo fmt --all
    cd documentation && bun install && bun run format-markdown
    dprint fmt
    forge fmt

# Clean up all build artifacts
clean: 
    @just localnet down
    @echo "Cleaning up..."
    @rm -rf {{LOGS_DIR}} ./broadcast
    cargo clean
    forge clean
    @echo "Cleanup complete."

# Manage the development network (up or down, defaults to up)
localnet action="up": check-deps
    #!/usr/bin/env bash
    # Localnet-specific variables
    ANVIL_PORT="8545"
    ANVIL_BLOCK_TIME="2"
    RISC0_DEV_MODE="${RISC0_DEV_MODE:-1}"
    CHAIN_KEY="anvil"
    RUST_LOG="info,broker=debug,boundless_market=debug,order_stream=debug"
    # This key is a prefunded address for the anvil test configuration (index 0)
    DEPLOYER_PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    ADMIN_ADDRESS="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    DEPOSIT_AMOUNT="100000000000000000000"
    
    if [ "{{action}}" = "up" ]; then
        mkdir -p {{LOGS_DIR}}
        
        # Create .env.localnet from template if it doesn't exist
        if [ ! -f .env.localnet ]; then
            echo "Creating .env.localnet from template..."
            cp .env.localnet-template .env.localnet || { echo "Error: .env.localnet-template not found"; exit 1; }
        fi
        
        echo "Building contracts..."
        forge build || { echo "Failed to build contracts"; just localnet down; exit 1; }
        echo "Building Rust project..."
        cargo build --bin order_stream || { echo "Failed to build order-stream binary"; just localnet down; exit 1; }
        cargo build --bin boundless || { echo "Failed to build boundless CLI binary"; just localnet down; exit 1; }
        # Check if Anvil is already running
        if nc -z localhost $ANVIL_PORT; then
            echo "Anvil is already running on port $ANVIL_PORT. Reusing existing instance."
        else
            echo "Starting Anvil..."
            anvil -b $ANVIL_BLOCK_TIME > {{LOGS_DIR}}/anvil.txt 2>&1 & echo $! >> {{PID_FILE}}
            sleep 5
        fi
        echo "Deploying contracts..."
        DEPLOYER_PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY CHAIN_KEY=$CHAIN_KEY RISC0_DEV_MODE=$RISC0_DEV_MODE BOUNDLESS_MARKET_OWNER=$ADMIN_ADDRESS forge script contracts/scripts/Deploy.s.sol --rpc-url http://localhost:$ANVIL_PORT --broadcast -vv || { echo "Failed to deploy contracts"; just localnet down; exit 1; }
        echo "Fetching contract addresses..."
        VERIFIER_ADDRESS=$(jq -re '.transactions[] | select(.contractName == "RiscZeroVerifierRouter") | .contractAddress' ./broadcast/Deploy.s.sol/31337/run-latest.json | head -n 1)
        SET_VERIFIER_ADDRESS=$(jq -re '.transactions[] | select(.contractName == "RiscZeroSetVerifier") | .contractAddress' ./broadcast/Deploy.s.sol/31337/run-latest.json | head -n 1)
        BOUNDLESS_MARKET_ADDRESS=$(jq -re '.transactions[] | select(.contractName == "ERC1967Proxy") | .contractAddress' ./broadcast/Deploy.s.sol/31337/run-latest.json | head -n 1)
        HIT_POINTS_ADDRESS=$(jq -re '.transactions[] | select(.contractName == "HitPoints") | .contractAddress' ./broadcast/Deploy.s.sol/31337/run-latest.json | head -n 1)
        echo "Contract deployed at addresses:"
        echo "VERIFIER_ADDRESS=$VERIFIER_ADDRESS"
        echo "SET_VERIFIER_ADDRESS=$SET_VERIFIER_ADDRESS"
        echo "BOUNDLESS_MARKET_ADDRESS=$BOUNDLESS_MARKET_ADDRESS"
        echo "HIT_POINTS_ADDRESS=$HIT_POINTS_ADDRESS"
        echo "Updating .env.localnet file..."
        # Update the environment variables in .env.localnet
        sed -i.bak "s/^export VERIFIER_ADDRESS=.*/export VERIFIER_ADDRESS=$VERIFIER_ADDRESS/" .env.localnet
        sed -i.bak "s/^export SET_VERIFIER_ADDRESS=.*/export SET_VERIFIER_ADDRESS=$SET_VERIFIER_ADDRESS/" .env.localnet
        sed -i.bak "s/^export BOUNDLESS_MARKET_ADDRESS=.*/export BOUNDLESS_MARKET_ADDRESS=$BOUNDLESS_MARKET_ADDRESS/" .env.localnet
        sed -i.bak "s/^export HIT_POINTS_ADDRESS=.*/export HIT_POINTS_ADDRESS=$HIT_POINTS_ADDRESS/" .env.localnet
        rm .env.localnet.bak
        echo ".env.localnet file updated successfully."
        
        # Mint stake to the address in the localnet template wallet
        DEFAULT_PRIVATE_KEY="0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"
        DEFAULT_ADDRESS="0x90F79bf6EB2c4f870365E785982E1f101E93b906"
        
        echo "Minting HP for prover address."
        cast send --private-key $DEPLOYER_PRIVATE_KEY \
            --rpc-url http://localhost:$ANVIL_PORT \
            $HIT_POINTS_ADDRESS "mint(address, uint256)" $DEFAULT_ADDRESS $DEPOSIT_AMOUNT

        # Start order stream server
        just test-db setup
        echo "Starting order stream server..."
        DATABASE_URL={{DATABASE_URL}} RUST_LOG=$RUST_LOG ./target/debug/order_stream \
            --rpc-url http://localhost:$ANVIL_PORT \
            --min-balance-raw 0 \
            --bypass-addrs="0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f" \
            --boundless-market-address $BOUNDLESS_MARKET_ADDRESS > {{LOGS_DIR}}/order_stream.txt 2>&1 & echo $! >> {{PID_FILE}}
        
        echo "Depositing stake using boundless CLI..."
        RPC_URL=http://localhost:$ANVIL_PORT \
        PRIVATE_KEY=$DEFAULT_PRIVATE_KEY \
        BOUNDLESS_MARKET_ADDRESS=$BOUNDLESS_MARKET_ADDRESS \
        SET_VERIFIER_ADDRESS=$SET_VERIFIER_ADDRESS \
        VERIFIER_ADDRESS=$VERIFIER_ADDRESS \
        ./target/debug/boundless account deposit-stake 100 || echo "Note: Stake deposit failed, but this is non-critical for localnet setup"
        
        echo "Localnet is running with RISC0_DEV_MODE=$RISC0_DEV_MODE"
        if [ ! -f broker.toml ]; then
            echo "Creating broker.toml from template..."
            cp broker-template.toml broker.toml || { echo "Error: broker-template.toml not found"; exit 1; }
            echo "broker.toml created successfully."
        fi
        echo "Make sure to run 'source .env.localnet' to load the environment variables before interacting with the network."
        echo "To start the broker manually, run:"
        echo "source .env.localnet && cargo run --bin broker"
    elif [ "{{action}}" = "down" ]; then
        if [ -f {{PID_FILE}} ]; then
            while read pid; do
                kill $pid 2>/dev/null || true
            done < {{PID_FILE}}
            rm {{PID_FILE}}
        fi
        just test-db clean
    elif [ "{{action}}" = "logs" ]; then
        if [ ! -f {{PID_FILE}} ]; then
            echo "localnet is not running" >/dev/stderr; exit 1
        fi
        tail -F {{LOGS_DIR}}/*
    else
        echo "Unknown action: {{action}}"
        echo "Available actions: up, down"
        exit 1
    fi

# Update cargo dependencies
cargo-update:
    cargo update
    cd examples/counter && cargo update

# Start the bento service
bento action="up" env_file="" compose_flags="" detached="true":
    #!/usr/bin/env bash
    if [ -n "{{env_file}}" ]; then
        ENV_FILE_ARG="--env-file {{env_file}}"
    else
        ENV_FILE_ARG=""
    fi

    if ! command -v docker &> /dev/null; then
        echo "Error: Docker command is not available. Please make sure you have docker in your PATH."
        exit 1
    fi

    if ! docker compose version &> /dev/null; then
        echo "Error: Docker compose command is not available. Please make sure you have docker in your PATH."
        exit 1
    fi

    if [ "{{action}}" = "up" ]; then
        if [ -n "{{env_file}}" ] && [ ! -f "{{env_file}}" ]; then
            echo "Error: Environment file {{env_file}} does not exist."
            exit 1
        fi

        echo "Starting Docker Compose services"
        if [ -n "{{env_file}}" ]; then
            echo "Using environment file: {{env_file}}"
        else
            echo "Using default values from compose.yml"
        fi
        
        if [ "{{detached}}" = "true" ]; then
            DETACHED_FLAG="-d"
        else
            DETACHED_FLAG=""
        fi
        
        docker compose {{compose_flags}} $ENV_FILE_ARG up --build $DETACHED_FLAG
        if [ "{{detached}}" != "true" ]; then
            echo "Docker Compose services have been started."
        fi
    elif [ "{{action}}" = "down" ]; then
        echo "Stopping Docker Compose services"
        if docker compose {{compose_flags}} $ENV_FILE_ARG down; then
            echo "Docker Compose services have been stopped and removed."
        else
            echo "Error: Failed to stop Docker Compose services."
            exit 1
        fi
    elif [ "{{action}}" = "clean" ]; then
        echo "Stopping and cleaning Docker Compose services"
        if docker compose {{compose_flags}} $ENV_FILE_ARG down -v; then
            echo "Docker Compose services have been stopped and volumes have been removed."
        else
            echo "Error: Failed to clean Docker Compose services."
            exit 1
        fi
    elif [ "{{action}}" = "logs" ]; then
        echo "Docker logs"
        docker compose {{compose_flags}} $ENV_FILE_ARG logs -f
    else
        echo "Unknown action: {{action}}"
        echo "Available actions: up, down, clean, logs"
        exit 1
    fi

# Run the broker service with a bento cluster for proving.
broker action="up" env_file="" detached="true":
    #!/usr/bin/env bash
    # Check if broker.toml exists, if not create it from template
    if [ ! -f broker.toml ]; then
        echo "Creating broker.toml from template..."
        cp broker-template.toml broker.toml || { echo "Error: broker-template.toml not found"; exit 1; }
        echo "broker.toml created successfully."
    fi
    
    just bento "{{action}}" "{{env_file}}" "--profile broker" "{{detached}}"

# Run the setup script
bento-setup:
    #!/usr/bin/env bash
    ./scripts/setup.sh

# Check job status in Postgres
job-status job_id:
    #!/usr/bin/env bash
    ./scripts/job_status.sh {{job_id}}
