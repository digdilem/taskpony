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

# Start the app using Starman via Carton
# --workers 5: Adjust this based on your CPU cores (usually cores * 2 + 1)
# --preload-app: Highly recommended for performance/memory sharing
CMD ["carton", "exec", "starman", "--port", "5000", "--workers", "2", "--preload-app", "taskpony.psgi"]







# #FROM perl:5.38
# FROM perl:5.38-slim-bookworm

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

