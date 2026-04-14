FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TERM=xterm-256color \
    HOME=/home/cc

# Base tooling + ttyd dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg lsb-release \
      git openssh-client tmux less vim nano jq ripgrep \
      build-essential python3 python3-pip python3-venv \
      ttyd tini \
 && rm -rf /var/lib/apt/lists/*

# Node.js 20 LTS (pour Claude Code CLI)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

# kubectl
RUN curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl

# Ansible (via pipx pour rester propre)
RUN pip3 install --no-cache-dir --break-system-packages ansible

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Utilisateur non-root
RUN useradd -m -u 1000 -s /bin/bash cc \
 && mkdir -p /home/cc/.ssh /home/cc/workspace \
 && chown -R cc:cc /home/cc

# Config tmux minimale — mouse support, historique long
RUN printf 'set -g mouse on\nset -g history-limit 50000\nset -g default-terminal "screen-256color"\nset -g status-right "#[fg=cyan]#H"\n' \
      > /home/cc/.tmux.conf \
 && chown cc:cc /home/cc/.tmux.conf

# Alias pratiques
RUN printf '\n# cc aliases\nalias cc="claude"\nalias k="kubectl"\nexport KUBECONFIG=$HOME/.kube/config\n' \
      >> /home/cc/.bashrc

# Entrypoint : ttyd -> tmux -A (attach si existe, sinon crée)
# -W = writable, -t fontSize, auth basic via env TTYD_CREDENTIAL
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER cc
WORKDIR /home/cc

EXPOSE 7681

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
