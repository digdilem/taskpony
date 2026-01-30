# Use the official Perl 5.38 Slim image (Debian Bookworm)
FROM perl:5.38-slim-bookworm

# 1. Install build tools and SQLite dev libraries
# 2. Install Starman and Carton
# 3. Clean up the compiler and cache to keep the image slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    libsqlite3-dev && \
    cpanm --notest Carton Starman && \
    rm -rf /var/lib/apt/lists/* /root/.cpanm

WORKDIR /opt/taskpony

# Copy dependency files first for better Docker layer caching
COPY cpanfile* ./

# Install app dependencies via Carton
# This will now succeed because build-essential is present
RUN carton install

# Copy the rest of your application code
COPY static/ static/
COPY taskpony.psgi taskpony.psgi
COPY README.md README.md

# Set environment paths so Perl finds the libraries installed by Carton
ENV PERL5LIB="/opt/taskpony/local/lib/perl5"
ENV PATH="/opt/taskpony/local/bin:${PATH}"

# Starman runs on port 5000 by default in this config
EXPOSE 5000

# Sticking with plackup for lower memory use and for the single-threaded nature of the app
#CMD ["carton", "exec", "starman", "--port", "5000", "--workers", "2", "--preload-app", "taskpony.psgi"]
CMD ["carton", "exec", "plackup", "-p", "5000", "taskpony.psgi"]

# End of file
