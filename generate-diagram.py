#!/usr/bin/env python3
"""
Generate Ollama on EKS architecture diagram with AWS service icons.

Usage:
    python generate-diagram.py

Output:
    docs/architecture.png

Requirements:
    pip install diagrams
    brew install graphviz   # macOS
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.aws.compute import EC2
from diagrams.aws.network import TransitGateway, NLB
from diagrams.aws.storage import EBS
from diagrams.aws.general import User
from diagrams.onprem.network import Kong, Istio
from diagrams.k8s.compute import Pod
from diagrams.k8s.network import SVC as Svc

# ── Global graph attributes ───────────────────────────────────────────────────
graph_attr = {
    "fontsize": "13",
    "fontname": "Helvetica",
    "bgcolor": "white",
    "pad": "0.75",
    "nodesep": "0.50",
    "ranksep": "0.90",
    "dpi": "150",
    "splines": "ortho",
}

node_attr = {
    "fontsize": "11",
    "fontname": "Helvetica",
}

# ── Build diagram ─────────────────────────────────────────────────────────────
with Diagram(
    name="Ollama on EKS — Private LLM Infrastructure",
    filename="docs/architecture",
    outformat="png",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
    node_attr=node_attr,
):
    # ── Team Members ──────────────────────────────────────────────────────────
    with Cluster("Team — Any Device · Any Location"):
        claude_code = User("Claude Code\nqwen3-coder:32b")
        api_client  = User("OpenAI-compatible\nClient")

    # ── Kong Inc's Managed AWS Account ────────────────────────────────────────
    with Cluster(
        "KONG INC — Managed AWS Account\n(You never operate this infrastructure)",
        graph_attr={
            "bgcolor": "#dcfce7",
            "pencolor": "#16a34a",
            "penwidth": "3",
            "fontcolor": "#14532d",
            "fontsize": "12",
        },
    ):
        kong_gw = Kong(
            "Kong Cloud AI Gateway\n"
            "ai-proxy  ·  key-auth\n"
            "ai-rate-limiting  ·  prometheus"
        )

    # ── Your AWS Account ──────────────────────────────────────────────────────
    with Cluster(
        "YOUR AWS ACCOUNT — us-west-2\n"
        "(You own · You control · Your prompts never leave)",
        graph_attr={
            "bgcolor": "#fef9c3",
            "pencolor": "#d97706",
            "penwidth": "3",
            "fontcolor": "#78350f",
            "fontsize": "12",
        },
    ):
        tgw = TransitGateway(
            "Transit Gateway\n"
            "RAM Share → Kong account\n"
            "Private bridge  ·  never internet"
        )

        with Cluster(
            "VPC  10.0.0.0/16  ·  Private Subnets  ·  NAT Gateway",
            graph_attr={
                "bgcolor": "#eff6ff",
                "pencolor": "#60a5fa",
                "penwidth": "2",
            },
        ):
            with Cluster(
                "istio-ingress namespace",
                graph_attr={
                    "bgcolor": "#e0e7ff",
                    "pencolor": "#6366f1",
                    "penwidth": "2",
                },
            ):
                nlb      = NLB("Internal NLB\n(not internet-facing)")
                istio_gw = Istio("Istio Gateway\nGateway API  ·  mTLS")

            with Cluster(
                "EKS Cluster  ·  Kubernetes 1.31",
                graph_attr={
                    "bgcolor": "#e0f2fe",
                    "pencolor": "#0284c7",
                    "penwidth": "2",
                },
            ):
                sys_nodes = EC2("System Nodes\n2× t3.medium")
                gpu_node  = EC2("GPU Node\ng5.12xlarge\n4× NVIDIA A10G  ·  96 GB VRAM")

                with Cluster(
                    "ollama namespace\n(NetworkPolicy: istio-ingress only)",
                    graph_attr={
                        "bgcolor": "#fce7f3",
                        "pencolor": "#db2777",
                        "penwidth": "2",
                    },
                ):
                    svc = Svc("ClusterIP  :11434\nnever internet-exposed")
                    pod = Pod("Ollama Pod\n4× GPU  ·  96 GB VRAM\nqwen3-coder:32b")

            # EBS is an AWS-native service — NOT inside EKS or the K8s namespace.
            # The EBS CSI Driver calls AWS APIs to attach the volume directly to the
            # EC2 GPU node as a virtual NVMe block device (Nitro hypervisor-level).
            # kubelet then mounts it into the pod — no network socket involved.
            vol = EBS(
                "EBS gp3  ·  200 GB\n"
                "AZ-local AWS block storage\n"
                "Attached to EC2 via Nitro NVMe\n"
                "Retain policy  ·  4000 IOPS"
            )

    # ── Traffic flow — numbered steps ─────────────────────────────────────────
    [claude_code, api_client] >> Edge(label="① HTTPS") >> kong_gw

    kong_gw >> Edge(
        label="② Private peering\nKong CIDR: 192.168.0.0/16\nnever over internet"
    ) >> tgw

    tgw >> Edge(label="③ VPC attachment\n10.0.0.0/16") >> nlb

    nlb >> Edge(label="④") >> istio_gw

    istio_gw >> Edge(label="⑤ HTTPRoute → :11434") >> svc

    svc >> Edge(label="⑥") >> pod

    # EBS attaches to the EC2 GPU node at the hypervisor level (Nitro NVMe).
    # kubelet on that node mounts it into the Ollama pod as /root/.ollama.
    # This is NOT PrivateLink — it is a block device, not a network connection.
    gpu_node >> Edge(
        label="NVMe block device\n(Nitro hypervisor attach)",
        style="dashed",
        color="#6b7280",
    ) >> vol

    pod >> Edge(
        label="PVC mount\n/root/.ollama",
        style="dashed",
        color="#6b7280",
    ) >> vol
