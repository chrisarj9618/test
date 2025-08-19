FROM debian:stable-slim

# Build tools you need…
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl openssh-server git git-lfs \
 && rm -rf /var/lib/apt/lists/*

# Install GitLab Runner binary (puts it in PATH)
RUN curl -L --output /usr/local/bin/gitlab-runner \
      https://gitlab-runner-downloads.s3.amazonaws.com/latest/binaries/gitlab-runner-linux-amd64 \
 && chmod +x /usr/local/bin/gitlab-runner

# Minimal sshd setup
RUN mkdir -p /var/run/sshd /root/.ssh
EXPOSE 22
CMD ["/usr/sbin/sshd","-D","-e"]
