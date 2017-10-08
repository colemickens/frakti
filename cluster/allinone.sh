#!/bin/bash

# Copyright 2017 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

set -x

if [ "${TMUX:-}" == "" ]; then
    exec tmux new-session -d -s k8s "export HOME=/root; ${0}; /bin/bash"
fi

FRAKTI_VERSION="v1.1"
CLUSTER_CIDR="10.244.0.0/16"
MASTER_CIDR="10.244.1.0/24"

install-hyperd-ubuntu() {
    apt-get update && apt-get install -y gcc qemu qemu-kvm libvirt0 libvirt-bin
    curl -sSL https://hypercontainer.io/install | sed '/tput/d' | bash
    echo -e "Kernel=/var/lib/hyper/kernel\n\
Initrd=/var/lib/hyper/hyper-initrd.img\n\
Hypervisor=kvm\n\
StorageDriver=overlay\n\
gRPCHost=127.0.0.1:22318" > /etc/hyper/config
    systemctl enable hyperd
    systemctl restart hyperd
}

install-docker-ubuntu() {
    curl -fsSL get.docker.com -o get-docker.sh
    sh get-docker.sh
    systemctl start docker
}

install-docker-centos() {
    yum install -y docker
    systemctl enable docker
    systemctl start docker
}

install-frakti() {
    curl -sSL https://github.com/kubernetes/frakti/releases/download/${FRAKTI_VERSION}/frakti -o /usr/bin/frakti
    chmod +x /usr/bin/frakti
    cgroup_driver=$(docker info | awk '/Cgroup Driver/{print $3}')
    cat <<EOF > /lib/systemd/system/frakti.service
[Unit]
Description=Hypervisor-based container runtime for Kubernetes
Documentation=https://github.com/kubernetes/frakti
After=network.target
[Service]
ExecStart=/usr/bin/frakti --v=3 \
          --log-dir=/var/log/frakti \
          --logtostderr=false \
          --cgroup-driver=${cgroup_driver} \
          --listen=/var/run/frakti.sock \
          --streaming-server-addr=%H \
          --hyper-endpoint=127.0.0.1:22318
MountFlags=shared
TasksMax=8192
LimitNOFILE=1048576
LimitNPROC=1048576
LimitCORE=infinity
TimeoutStartSec=0
Restart=on-abnormal
[Install]
WantedBy=multi-user.target
EOF
    systemctl enable frakti
    systemctl start frakti
}

install-kubelet-centos() {
    cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=http://yum.kubernetes.io/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg
       https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF
    setenforce 0
    sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
    yum install -y kubernetes-cni kubelet kubeadm kubectl
}

install-kubelet-ubuntu() {
    apt-get update && apt-get install -y apt-transport-https
    curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
    cat <<EOF > /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
    apt-get update
    apt-get install -y kubelet kubeadm kubectl

    echo "source <(kubectl completion bash)" >> /etc/bash.bashrc
    echo "export KUBECONFIG=\"/etc/kubernetes/admin.conf\"" >> /etc/bash.bashrc
}

install-cni() {
    curl https://godeb.s3.amazonaws.com/godeb-amd64.tar.gz | tar xvzf -
    ./godeb install
    
    mkdir -p /opt/cni/bin
    GOPATH=/gopath
    mkdir -p $GOPATH/src/github.com/containernetworking/plugins
    git clone https://github.com/containernetworking/plugins $GOPATH/src/github.com/containernetworking/plugins
    (cd $GOPATH/src/github.com/containernetworking/plugins
    ./build.sh
    cp bin/* /opt/cni/bin/)
}

config-kubelet() {
    mkdir -p /etc/systemd/system/kubelet.service.d/
    cat > /etc/systemd/system/kubelet.service.d/20-cri.conf <<EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--cgroup-driver=systemd --container-runtime=remote --container-runtime-endpoint=unix:///var/run/frakti.sock --feature-gates=AllAlpha=true"
EOF
    systemctl daemon-reload
    systemctl restart kubelet
}

config-cni() {
    mkdir -p /etc/cni/net.d
    cat >/etc/cni/net.d/10-mynet.conflist <<-EOF
{
    "cniVersion": "0.3.1",
    "name": "mynet",
    "plugins": [
        {
            "type": "bridge",
            "bridge": "cni0",
            "isGateway": true,
            "ipMasq": true,
            "ipam": {
                "type": "host-local",
                "subnet": "${MASTER_CIDR}",
                "routes": [
                    { "dst": "0.0.0.0/0"  }
                ]
            }
        },
        {
            "type": "portmap",
            "capabilities": {"portMappings": true},
            "snat": true
        },
        {
            "type": "loopback"
        }
    ]
}
EOF
}

setup-master() {
    kubeadm reset
    config-cni # TODO: refactor better

    kubeadm init --pod-network-cidr ${CLUSTER_CIDR} --kubernetes-version stable

    # Also enable schedule pods on the master for allinone.
    export KUBECONFIG=/etc/kubernetes/admin.conf
    chmod 0644 ${KUBECONFIG}
    kubectl taint nodes --all node-role.kubernetes.io/master-

    # approve kublelet's csr for the node.
    sleep 30
    kubectl certificate approve $(kubectl get csr | awk '/^csr/{print $1}')

    # increase memory limits for kube-dns
    kubectl -n kube-system patch deployment kube-dns -p '{"spec":{"template":{"spec":{"containers":[{"name":"kubedns","resources":{"limits":{"memory":"256Mi"}}},{"name":"dnsmasq","resources":{"limits":{"memory":"128Mi"}}},{"name":"sidecar","resources":{"limits":{"memory":"64Mi"}}}]}}}}'
}

command_exists() {
    command -v "$@" > /dev/null 2>&1
}

lsb_dist=''
if command_exists lsb_release; then
    lsb_dist="$(lsb_release -si)"
fi
if [ -z "$lsb_dist" ] && [ -r /etc/lsb-release ]; then
    lsb_dist="$(. /etc/lsb-release && echo "$DISTRIB_ID")"
fi
if [ -z "$lsb_dist" ] && [ -r /etc/centos-release ]; then
    lsb_dist='centos'
fi
if [ -z "$lsb_dist" ] && [ -r /etc/redhat-release ]; then
    lsb_dist='redhat'
fi
if [ -z "$lsb_dist" ] && [ -r /etc/os-release ]; then
    lsb_dist="$(. /etc/os-release && echo "$ID")"
fi

lsb_dist="$(echo "$lsb_dist" | tr '[:upper:]' '[:lower:]')"

case "$lsb_dist" in

    ubuntu)
        install-hyperd-ubuntu
        install-docker-ubuntu
        install-frakti
        install-kubelet-ubuntu
        install-cni
        config-cni
        #config-gce-kubeadm
        config-kubelet
        setup-master
    ;;

    *)
        echo "$lsb_dist is not supported (not in ubuntu)"
    ;;

esac

config-gce-kubeadm() {
    EXTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
    INTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)
    KUBERNETES_VERSION=$(curl -s -H "Metadata-Flavor: Google" \
    http://metadata.google.internal/computeMetadata/v1/instance/attributes/kubernetes-version)

    cat <<EOF > kubeadm.conf
kind: MasterConfiguration
apiVersion: kubeadm.k8s.io/v1alpha1
apiServerCertSANs:
  - 10.96.0.1
  - ${EXTERNAL_IP}
  - ${INTERNAL_IP}
apiServerExtraArgs:
  admission-control: PodPreset,Initializers,GenericAdmissionWebhook,NamespaceLifecycle,LimitRanger,ServiceAccount,PersistentVolumeLabel,DefaultStorageClass,DefaultTolerationSeconds,NodeRestriction,ResourceQuota
  feature-gates: AllAlpha=true
  runtime-config: api/all
cloudProvider: gce
kubernetesVersion: ${KUBERNETES_VERSION}
networking:
  podSubnet: 192.168.0.0/16
EOF
}
