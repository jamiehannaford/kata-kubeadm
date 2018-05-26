#!/bin/bash

# cni
VERSION=1.1.0
wget https://storage.googleapis.com/cri-containerd-release/cri-containerd-${VERSION}.linux-amd64.tar.gz
tar -C / -xzf cri-containerd-${VERSION}.linux-amd64.tar.gz
systemctl start containerd

# install docker
apt-get -y install apt-transport-https ca-certificates wget software-properties-common
curl -sL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
arch=$(dpkg --print-architecture)
add-apt-repository "deb [arch=${arch}] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get update
apt-get -y install docker-ce

# install kata
sh -c "echo 'deb http://download.opensuse.org/repositories/home:/katacontainers:/release/xUbuntu_$(lsb_release -rs)/ /' > /etc/apt/sources.list.d/kata-containers.list"
curl -sL  http://download.opensuse.org/repositories/home:/katacontainers:/release/xUbuntu_$(lsb_release -rs)/Release.key | apt-key add -
apt-get update
apt-get -y install kata-runtime kata-proxy kata-shim

# configure kata and docker
mkdir -p /etc/systemd/system/docker.service.d/
cat <<EOF | sudo tee /etc/systemd/system/docker.service.d/kata-containers.conf
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -D --add-runtime kata-runtime=/usr/bin/kata-runtime --default-runtime=kata-runtime
EOF

systemctl daemon-reload
systemctl restart docker

# install k8s components
apt-get update && apt-get install -y apt-transport-https curl
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
apt-get update
apt-get install -y kubelet kubeadm kubectl

# configure untrusted runtime
mkdir -p /etc/containerd/
cat << EOT | sudo tee /etc/containerd/config.toml
[plugins]
    [plugins.cri.containerd]
      [plugins.cri.containerd.untrusted_workload_runtime]
        runtime_type = "io.containerd.runtime.v1.linux"
        runtime_engine = "/usr/bin/kata-runtime"
EOT

# configure kubelet
mkdir -p  /etc/systemd/system/kubelet.service.d/
cat << EOF | sudo tee  /etc/systemd/system/kubelet.service.d/0-containerd.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--container-runtime=remote --runtime-request-timeout=15m --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF
systemctl daemon-reload
systemctl restart containerd

# Prevent docker iptables rules conflict with k8s pod communication
iptables -P FORWARD ACCEPT

# weave needs this
sysctl net.bridge.bridge-nf-call-iptables=1

# Start cluster using kubeadm
if [ -n "$MASTER" ]; then
kubeadm init --skip-preflight-checks \
  --cri-socket /run/containerd/containerd.sock \
  --pod-network-cidr=10.244.0.0/16
else
kubeadm join 10.142.0.5:6443 \
  --cri-socket /run/containerd/containerd.sock \
  --token r22t2j.wgjebup5udzb8vm9 \
  --discovery-token-ca-cert-hash sha256:35cbd21b3cc236ee4805b74ecf0fc39a9470ab7ebdbb79e9f902175746624ead
fi
