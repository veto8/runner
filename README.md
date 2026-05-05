## The "Runner" Service: Your Post-Startup Task Executor

This setup allows you to define a dedicated Docker container, the "runner," that executes specific scripts *after* your other essential services (like databases or web applications) have started and are ready. This is invaluable for tasks such as:

*   Database migrations
*   Data seeding
*   Cache warming
*   Post-deployment cleanup or configuration

### Key Components:

1.  **`docker-compose.yml`:** Defines the services, including your `runner`.
2.  **`runner.sh` (or similar):** The script that the `runner` container will execute.
3.  **Docker Image:** The image for your `runner` container (e.g., `myridia/runner`).

### Example: `docker-compose.yml`

```yaml
# docker-compose.yml

version: '3.8'

services:
  # ... your other services like 'db', 'web', etc.
  # Ensure your 'db' and 'web' services are listed here as examples.
  db:
    image: postgres:13
    environment:
      POSTGRES_DB: mydatabase
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: mypassword # Consider using .env for secrets
    ports:
      - "5432:5432"
    networks:
      workgroup:
        ipv4_address: "10.5.0.3" # Example IP

  web:
    image: nginx:latest
    ports:
      - "80:80"
    depends_on:
      - db
    networks:
      workgroup:
        ipv4_address: "10.5.0.4" # Example IP

  runner:
    container_name: runner # Helpful for debugging
    image: "myridia/runner" # Your custom runner image
    volumes:
      # Mount your runner script into the container
      - ./runner.sh:/runner.sh
    depends_on:
      # Ensures runner starts ONLY after db and web are UP (but not necessarily ready)
      - db
      - web
    networks:
      workgroup:
        ipv4_address: "10.5.0.5" # Specific IP for the runner
    # The entrypoint is crucial: it tells Docker to execute your script
    entrypoint: ["/bin/bash", "/runner.sh"]
    # If you need to pass secrets, use environment variables (see notes below)
    # environment:
    #   POSTGRES_PASSWORD: ${MY_DB_PASSWORD} # Example: fetched from .env or shell env
    #   OTHER_SECRET: ${SOME_OTHER_SECRET}

networks:
  workgroup:
    driver: bridge
    ipam:
      config:
        - subnet: 10.5.0.0/24
```

---

### Example: `runner.sh` (Robust Script)

This script includes improved error handling and a more robust database check.

```bash
#!/bin/bash
# runner.sh

# --- Configuration ---
# Adjust these to match your environment
DB_HOST="10.5.0.3" # IP address of your database service (or 'db' if on same Docker network and DNS works)
DB_PORT="5432"
DB_USER="odoo" # Example user
DB_NAME="odoo" # Example database name
DB_PASSWORD="YOURPASSWORD" # !! IMPORTANT: Use environment variables or Docker Secrets for production !!

# --- Script Execution ---

# Exit immediately if a command exits with a non-zero status.
set -e

echo "--- Runner Script Started ---"

# 1. Wait for the Database to be Ready
echo "Waiting for PostgreSQL database at ${DB_HOST}:${DB_PORT} to become available..."

MAX_RETRIES=60 # Number of times to check
RETRY_INTERVAL=2 # Seconds between checks
RETRY_COUNT=0

# Use psql to check connectivity. Redirect output to /dev/null as we only care about the exit code.
# The `-w` flag disables password prompts, which is essential for non-interactive scripts.
while ! PGPASSWORD=$DB_PASSWORD psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -w -c '\q' > /dev/null 2>&1; do
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "ERROR: Database connection failed after ${MAX_RETRIES} retries. Exiting."
        exit 1
    fi
    echo "Database not ready. Retrying in ${RETRY_INTERVAL} seconds... (Attempt ${RETRY_COUNT}/${MAX_RETRIES})"
    sleep $RETRY_INTERVAL
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

echo "Database is ready!"

# 2. Perform Your Specific Tasks
echo "Executing database cleanup task..."

# Example: Delete Odoo's ir_attachment records for views to force recreation
# Ensure DB_PASSWORD is set correctly here (either via export, or directly as above)
# Using PGPASSWORD environment variable is the standard way for psql.
export PGPASSWORD=$DB_PASSWORD
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "DELETE FROM ir_attachment WHERE res_model='ir.ui.view' AND name LIKE '%assets_%';"

echo "Database cleanup task completed successfully."

# Add more tasks here as needed
# echo "Running another task..."
# curl -sSf http://web:80/api/v1/init-data || echo "Warning: Failed to initialize data."

echo "--- Runner Script Finished Successfully ---"

```

---

### **Security Note on Passwords:**

*   **Never hardcode production passwords directly in the `.sh` script or `docker-compose.yml`.**
*   **Recommended:** Use Docker Secrets or environment variables passed from a `.env` file or your CI/CD system.
    *   **`.env` file:** Create a file named `.env` in the same directory as `docker-compose.yml`:
        ```
        MY_DB_PASSWORD=your_actual_super_secret_password
        OTHER_SECRET=some_value
        ```
        Then, in `docker-compose.yml`, reference it like: `POSTGRES_PASSWORD: ${MY_DB_PASSWORD}`.
    *   The `runner.sh` script can then read these from the container's environment variables, e.g., `DB_PASSWORD=${POSTGRES_PASSWORD}` or directly access them if they are exported by Docker.

---

### Integration with CI/CD Tools (GitHub Actions, GitLab CI, etc.)

This runner pattern is excellent for CI/CD pipelines. The `myridia/runner` image can be used with various tools that orchestrate Docker containers.

**The Core Idea:**

You need a tool that can:
1.  Start your application services (DB, Web, etc.) in Docker.
2.  Run a specific container (`myridia/runner`) *after* the others.
3.  Pass necessary configuration (like secrets) to the runner.

**Example with `act` (for GitHub Actions locally):**

`act` simulates GitHub Actions locally. You define your workflow in `.github/workflows/deploy.yml` and use `act` to run it.

*   **`docker-compose.yml`:** Remains the same as above.
*   **`.github/workflows/deploy.yml`:** (Simplified Example)

    ```yaml
    name: Deploy Workflow

    on:
      push:
        branches: [ main ]

    jobs:
      deploy:
        runs-on: ubuntu-latest # Or your preferred runner OS
        steps:
          - name: Checkout code
            uses: actions/checkout@v3

          # Use a service container for Docker Compose
          # Assumes Docker is running on the runner
          - name: Set up Docker Compose
            uses: arrterian/docker-compose-action@v1.2.0
            with:
              command: up -d db web # Start only the necessary services

          - name: Run Runner Container
            uses: arrterian/docker-compose-action@v1.2.0
            with:
              compose-file: docker-compose.yml
              command: run --rm runner # 'run --rm' starts the container, executes command, then removes it.
                                       # The 'entrypoint' from docker-compose.yml will be used.
            env:
              # Pass secrets from GitHub Actions secrets
              MY_DB_PASSWORD: ${{ secrets.DB_PASSWORD }}

          # Add more steps here if needed
    ```

*   **Local `act` command:**
    If you're running `act` locally and want to simulate this, you can use the `-W` flag to specify your `docker-compose.yml` and map services.

    ```bash
    # Simulate running the deploy.yml workflow locally using act
    # -W deploy.yaml: Specifies the workflow file
    # --secret DB_PASSWORD=your_local_db_password: Provides secrets
    # -P docker3=myridia/runner: Maps a service name (e.g., 'runner' from your compose) to your custom image
    # --pull=false: Avoids pulling images if they exist locally (faster testing)

    act --workflow-file .github/workflows/deploy.yml \
        --secret DB_PASSWORD=your_local_db_password \
        -P docker3=myridia/runner \
        --pull=false \
        deploy # Specifies the job name from your workflow
    ```
    *(Note: The exact `act` command might vary slightly depending on how you've structured your `docker-compose.yml` and workflow. The key is to have `act` orchestrate the `docker-compose up` or `docker-compose run` commands.)*

**Key Takeaway for CI/CD:**

The pattern is consistent:
1.  Start base services (`docker-compose up -d db web`).
2.  Execute the runner task (`docker-compose run --rm runner` or similar orchestration).
3.  Pass secrets securely.



### Definition

#### GitHub Actions Runner:
* A server/process that picks up jobs from your workflow and runs them
* It "runs" the steps defined in your .github/workflows/*.yml files
* Can be GitHub-hosted (provided by GitHub) or self-hosted (your own machine)

#### Docker (Docker Runner/Executor):
* Less commonly called "runner" directly, but tools like GitLab CI use "Docker runner" to mean a worker that spins up Docker containers to execute jobs
* It "runs" your build/test/deploy commands inside isolated containers
* The name is straightforward — it's the thing that runs your tasks.
