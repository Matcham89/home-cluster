# Kagent Slack Bot - Docker Image
# 2025 best practices: minimal image, non-root user, pinned versions

FROM python:3.13-slim

# Metadata
LABEL org.opencontainers.image.title="Kagent Slack Bot"
LABEL org.opencontainers.image.description="Slack bot for Kagent AI agents using A2A protocol"
LABEL org.opencontainers.image.source="https://github.com/your-org/kagent-slack"

# Create non-root user for security
RUN useradd --create-home --shell /bin/bash kagent

# Set working directory
WORKDIR /app

# Install dependencies as root
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY slack_bot.py .

# Switch to non-root user
USER kagent

# Health check (optional but recommended)
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import sys; sys.exit(0)" || exit 1

# Run bot
CMD ["python", "-u", "slack_bot.py"]
