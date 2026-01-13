########################################
# Builder stage
########################################
FROM alpine:3.20 AS builder

# Install build deps + perl modules
RUN apk add --no-cache \
    perl \
    perl-dev \
    perl-utils \
    perl-dbi \
    perl-dbd-sqlite \
    perl-carton \
    perl-app-cpanminus \
    build-base \
    curl \
    git \
    openssl-dev \
    sqlite-dev \
    ca-certificates

WORKDIR /opt/taskpony

# Copy dependency file for layer caching
COPY cpanfile cpanfile

# Install Perl dependencies via Carton
RUN carton install --deployment --without=test

########################################
# Runtime stage
########################################
FROM alpine:3.20

# Runtime-only deps
RUN apk add --no-cache \
    perl \
    perl-dbi \
    perl-dbd-sqlite \
    perl-carton \
    ca-certificates \
    && adduser -D -H -s /sbin/nologin appuser

WORKDIR /opt/taskpony

# Copy installed Perl libs and binaries from builder
COPY --from=builder /opt/taskpony/local /opt/taskpony/local

# Copy app files
COPY static/ static/
COPY taskpony.psgi taskpony.psgi
COPY README.md README.md

# Fix ownership
RUN chown -R appuser:appuser /opt/taskpony

USER appuser

ENV PERL5LIB=/opt/taskpony/local/lib/perl5
ENV PATH=/opt/taskpony/local/bin:$PATH

EXPOSE 5000

CMD ["carton", "exec", "plackup", "-p", "5000", "taskpony.psgi"]


# #FROM perl:5.38
# FROM cgr.dev/chainguard/perl

# # Install system packages for Sqlite
# RUN apt-get update && \
#     apt-get install -y libcpan-sqlite-perl && \
#     cpanm --notest Carton

# WORKDIR /opt/taskpony

# COPY Dockerfile Dockerfile
# COPY cpanfile cpanfile
# COPY static/ static/
# COPY taskpony.psgi taskpony.psgi
# COPY README.md README.md

# RUN ls -l && \
#     carton install

# COPY . .

# # Expose Plack on port 5000
# EXPOSE 5000

# # Start the PSGI app using plackup
# # We don't want it to automatically restart whenver the database changes, so we omit the --reload option.
# # CMD ["carton", "exec", "plackup", "-R", ".", "-p", "5000", "taskpony.psgi"]
# CMD ["carton", "exec", "plackup", "-p", "5000", "taskpony.psgi"]

# # End of file

