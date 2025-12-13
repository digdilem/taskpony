FROM perl:5.38

# Install system packages for Sqlite
RUN apt-get update && \
    apt-get install -y libcpan-sqlite-perl && \
    cpanm --notest Carton

WORKDIR /opt/taskpony

COPY Dockerfile Dockerfile
COPY cpanfile cpanfile
COPY static/ static/
COPY taskpony.psgi taskpony.psgi
COPY README.md README.md

RUN ls -l && \
    carton install

COPY . .

# Expose Plack on port 5000
EXPOSE 5000

# Start the PSGI app using plackup
# We don't want it to automatically restart whenver the database changes, so we omit the --reload option.
# CMD ["carton", "exec", "plackup", "-R", ".", "-p", "5000", "taskpony.psgi"]
CMD ["carton", "exec", "plackup", "-p", "5000", "taskpony.psgi"]

# End of file

