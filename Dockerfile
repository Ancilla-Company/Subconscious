# Use an official Python runtime as a parent image
FROM python:3.12-slim as builder

# Set the working directory in the container
WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Copy the project files
COPY . .

# Install the project and its dependencies
RUN pip install --no-cache-dir .

# Create a clean runtime image
FROM python:3.12-slim

WORKDIR /app

# Copy the installed packages from the builder
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin/subconscious /usr/local/bin/subconscious
COPY --from=builder /app /app

# Expose ports if necessary (e.g., for FastAPI)
EXPOSE 8000

# Set environment variables
ENV PYTHONUNBUFFERED=1

# Run the subconscious engine by default in the container
ENTRYPOINT ["subconscious"]
CMD ["engine"]
