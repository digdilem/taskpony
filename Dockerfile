# --- Stage 1: The Builder ---
FROM perl:5.38 AS builder

# Install system dependencies needed for building/compiling
RUN apt-get update && apt-get install -y \
    build-essential \
    libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

RUN cpanm --notest Carton

WORKDIR /opt/taskpony
COPY cpanfile cpanfile.snapshot* ./

# Install dependencies into a local directory (local/)
RUN carton install --deployment

# --- Stage 2: The Hardened Runtime ---
# Using the Docker Hardened Image (DHI) for Perl
FROM dhi.io/perl:5.38-slim

# If not using DHI, use: FROM perl:5.38-slim
WORKDIR /opt/taskpony

# Copy only the pre-installed Perl libraries from the builder
COPY --from=builder /opt/taskpony/local /opt/taskpony/local
COPY --from=builder /usr/local/bin /usr/local/bin

# Copy only necessary application files
COPY static/ static/
COPY taskpony.psgi taskpony.psgi
COPY README.md README.md

# Set environment so Perl knows where to find the 'carton' libraries
ENV PERL5LIB="/opt/taskpony/local/lib/perl5"
ENV PATH="/opt/taskpony/local/bin:${PATH}"

EXPOSE 5000

# Run as a non-root user (Standard practice for hardened images)
USER 1000

CMD ["plackup", "-p", "5000", "taskpony.psgi"]
