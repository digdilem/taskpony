FROM perl:5.38

# Install system packages for Sqlite
RUN apt-get update && \
    apt-get install -y libcpan-sqlite-perl && \
    cpanm --notest Carton

WORKDIR /opt/taskpony

COPY cpanfile cpanfile
COPY static/ static/
COPY taskpony.psgi taskpony.psgi
COPY READNE.md README.md

RUN carton install

COPY . .

# Expose Plack on port 5000
EXPOSE 5000

# Start the PSGI app using plackup
CMD ["carton", "exec", "plackup", "-R", ".", "-p", "5000", "taskpony.psgi"]

# End of file
s
