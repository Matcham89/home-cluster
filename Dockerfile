# Kube Dev Container with docker CLI, zsh/oh-my-zsh, kube-ps1, and K8s tools
FROM mcr.microsoft.com/devcontainers/base:ubuntu

# ---- Versions (pin for reproducibility) ----
ARG KUBECTL_VERSION=1.30.0
ARG HELM_VERSION=3.15.0
ARG FLUX_VERSION=2.3.0
ARG TERRAFORM_VERSION=1.8.5
ARG K9S_VERSION=0.32.4

USER root

# ---- Base packages + docker CLI ----
RUN apt-get update && apt-get install -y \
    curl wget unzip git jq zsh vim fzf ca-certificates bash-completion locales \
    docker.io \
 && rm -rf /var/lib/apt/lists/*

# Let vscode use docker.sock when mounted
RUN groupadd -f docker && usermod -aG docker vscode

# ---- kubectl ----
RUN curl -sSL -o /usr/local/bin/kubectl \
    https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl \
 && chmod +x /usr/local/bin/kubectl

# ---- Helm ----
RUN curl -sSL https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz \
  | tar xz \
 && mv linux-amd64/helm /usr/local/bin/ \
 && rm -rf linux-amd64

# ---- Flux ----
RUN curl -sSL https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_linux_amd64.tar.gz \
  | tar xz \
 && mv flux /usr/local/bin/

# ---- Terraform ----
RUN curl -sSL https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip -o /tmp/terraform.zip \
 && unzip /tmp/terraform.zip -d /usr/local/bin \
 && rm /tmp/terraform.zip

# ---- k9s ----
RUN curl -sSL https://github.com/derailed/k9s/releases/download/v${K9S_VERSION}/k9s_Linux_amd64.tar.gz \
  | tar xz \
 && mv k9s /usr/local/bin/

# ---- oh-my-zsh (idempotent) ----
RUN ZSH_DIR=/home/vscode/.oh-my-zsh && \
    [ -d "$ZSH_DIR" ] || git clone https://github.com/ohmyzsh/ohmyzsh.git "$ZSH_DIR" && \
    [ -f /home/vscode/.zshrc ] || cp "$ZSH_DIR"/templates/zshrc.zsh-template /home/vscode/.zshrc && \
    chown -R vscode:vscode /home/vscode/.oh-my-zsh /home/vscode/.zshrc

# ---- kube-ps1 in prompt (idempotent) ----
RUN git clone https://github.com/jonmosco/kube-ps1.git /home/vscode/.kube-ps1 || true && \
    grep -q "kube-ps1.sh" /home/vscode/.zshrc || \
      printf '\n# --- kube-ps1 ---\nsource /home/vscode/.kube-ps1/kube-ps1.sh\nPROMPT="$(kube_ps1) $PROMPT"\n' >> /home/vscode/.zshrc && \
    chown -R vscode:vscode /home/vscode/.kube-ps1

# ---- zsh QoL: completions + aliases + kubeconfig-perms fix ----
RUN grep -q "kubectl completion zsh" /home/vscode/.zshrc || \
      printf '\n# --- completions ---\n[[ $commands[kubectl] ]] && source <(kubectl completion zsh)\n[[ $commands[helm] ]] && source <(helm completion zsh)\n' >> /home/vscode/.zshrc && \
    sed -i 's/^plugins=(git)$/plugins=(git kubectl terraform)/' /home/vscode/.zshrc || true && \
    # Aliases
    grep -q "alias k=" /home/vscode/.zshrc || printf '\n# --- aliases ---\nalias k=kubectl\nalias kgp="kubectl get pods"\nalias kgns="kubectl get ns"\n' >> /home/vscode/.zshrc && \
    # kubeconfig permissions workaround (mounted from Windows is 0666/0644)
    grep -q "KUBECONFIG_SECURE" /home/vscode/.zshrc || \
      printf '\n# --- kubeconfig perms fix ---\n'\
'if [ -f "$HOME/.kube/config" ]; then\n'\
'  # If too-permissive, copy to a secure file and use that\n'\
'  PERM=$(stat -c %a "$HOME/.kube/config" 2>/dev/null || echo 644)\n'\
'  if [ "$PERM" -gt 600 ]; then\n'\
'    mkdir -p "$HOME/.kube"\n'\
'    cp "$HOME/.kube/config" "$HOME/.kube/config.secure"\n'\
'    chmod 600 "$HOME/.kube/config.secure"\n'\
'    export KUBECONFIG="$HOME/.kube/config.secure"\n'\
'  fi\n'\
'fi\n' >> /home/vscode/.zshrc && \
    chown vscode:vscode /home/vscode/.zshrc

# ---- Default user & shell ----
USER vscode
SHELL ["/bin/zsh", "-c"]
