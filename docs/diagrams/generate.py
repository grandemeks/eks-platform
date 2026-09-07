#!/usr/bin/env python3
"""Generates the README architecture diagrams.

    pip install diagrams && brew install graphviz
    python3 docs/diagrams/generate.py

Writes PNGs into docs/images/. The diagrams are code so they stay reviewable in
a pull request and cannot drift into a hand-drawn picture nobody updates.
"""

from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import ECR, EKS
from diagrams.aws.database import RDS
from diagrams.aws.network import ELB, NATGateway, Route53
from diagrams.custom import Custom
from diagrams.onprem.gitops import Argocd
from diagrams.onprem.logging import Loki
from diagrams.onprem.monitoring import Grafana, Prometheus
from diagrams.onprem.tracing import Tempo
from diagrams.onprem.vcs import Git

OUT = Path(__file__).resolve().parents[1] / "images"
OUT.mkdir(parents=True, exist_ok=True)

# The shipped icon set has no OpenTelemetry mark, bakes a wordmark into the
# Terraform one and a label into the Kubernetes ones, and draws "user" and
# "internet" as dark outlines that vanish on this background. icons/ holds the
# plain marks instead, rasterised from Iconify (logos set is CC0, mdi is
# Apache 2.0) so a regeneration needs no network access.
ICONS = Path(__file__).resolve().parent / "icons"


def icon(name, label):
    return Custom(label, str(ICONS / f"{name}.png"))

BG = "#161b22"
FG = "#e6edf3"
LINE = "#7d8590"
ACCENT = "#e3b341"

GRAPH = {
    "bgcolor": BG,
    "fontcolor": FG,
    "fontname": "Helvetica bold",
    "fontsize": "18",
    "pad": "0.5",
    "nodesep": "0.55",
    "ranksep": "1.0",
}
NODE = {"fontcolor": FG, "fontname": "Helvetica", "fontsize": "13"}
# fontcolor has to be repeated on each Edge; graphviz will not inherit it from
# edge_attr once a label is set, and the labels come out unreadably dark.
EDGE = {"color": LINE, "fontcolor": FG, "fontname": "Helvetica", "fontsize": "12"}
CLUSTER = {
    "bgcolor": "#1c2431",
    "fontcolor": FG,
    "fontname": "Helvetica",
    "fontsize": "15",
    "style": "rounded",
    "penwidth": "1.4",
    "pencolor": "#30363d",
}


def link(label="", dashed=False, color=LINE, constraint=True):
    # constraint=False draws an edge without letting it influence rank, which
    # is what keeps a node that receives several arrows from drifting a column
    # to the right of its siblings.
    return Edge(
        label=f"  {label}  " if label else "",
        style="dashed" if dashed else "solid",
        color=color,
        fontcolor=FG,
        fontsize="12",
        constraint="true" if constraint else "false",
    )


def diagram(name, filename, direction="LR"):
    return Diagram(
        name,
        filename=str(OUT / filename),
        outformat="png",
        show=False,
        direction=direction,
        graph_attr=GRAPH,
        node_attr=NODE,
        edge_attr=EDGE,
    )


def infrastructure():
    with diagram("Infrastructure and the request path", "infrastructure"):
        internet = icon("internet", "Internet")
        dns = Route53("Route53\nrecords by external-dns")

        with Cluster("VPC 10.0.0.0/16, 2 AZs", graph_attr=CLUSTER):
            with Cluster("Public subnets", graph_attr=CLUSTER):
                alb = ELB("ALB\nACM cert, TLS 1.3")
                nat = NATGateway("NAT gateway")

            with Cluster("Private subnets", graph_attr=CLUSTER):
                eks = EKS("EKS 1.35\n2 x t3.large")
                rds = RDS("PostgreSQL 18\ndb.t4g.micro, private")

        internet >> link("HTTPS") >> dns >> link("alias") >> alb
        alb >> link("target-type: ip") >> eks
        eks >> link("TLS 5432") >> rds

        # Egress only. Where it goes (ECR, Secrets Manager, STS) is not part of
        # the request path and drawing it doubles the height of the diagram.
        eks >> link("egress", dashed=True, constraint=False) >> nat


def delivery():
    with diagram("How a change reaches the cluster", "delivery"):
        dev = icon("developer", "Developer")
        repo = Git("GitHub\nmain")

        with Cluster("GitHub Actions", graph_attr=CLUSTER):
            pr = icon("github-actions", "pr-checks\nplan only")
            env = icon("github-actions", "environment\napply / destroy")
            rel = icon("github-actions", "app-release\nscan, sign, push")

        tf = icon("terraform", "Terraform")
        ecr = ECR("ECR\nimmutable tags")
        argo = Argocd("Argo CD\napp-of-apps")

        with Cluster("EKS, 9 Applications", graph_attr=CLUSTER):
            w0 = icon("kubernetes", "wave 0\ncontrollers")
            w1 = icon("kubernetes", "wave 1\nobservability")
            w2 = icon("kubernetes", "wave 2\ndemo-app")

        dev >> link("pull request") >> repo
        repo >> link() >> pr
        repo >> link() >> env >> link("apply") >> tf >> link("installs") >> argo
        repo >> link() >> rel >> link("OIDC") >> ecr
        # The GitOps loop: app-release commits the new digest, Argo CD reads it
        # back. Left unlabelled because a constraint-free edge parks its label
        # in whatever whitespace graphviz finds, far from the line it belongs to.
        rel >> link(dashed=True, color=ACCENT, constraint=False) >> repo
        repo >> link(dashed=True, color=ACCENT, constraint=False) >> argo
        argo >> link() >> w0
        argo >> link() >> w1
        argo >> link() >> w2


def observability():
    with diagram("Observability data flow", "observability"):
        app = icon("kubernetes", "demo-app\nmetrics, spans, logs")
        collector = icon("opentelemetry", "OTel Collector\nDaemonSet, hostPort")

        with Cluster("monitoring", graph_attr=CLUSTER):
            prom = Prometheus("Prometheus\nexemplars, 7d")
            tempo = Tempo("Tempo\n24h")
            loki = Loki("Loki\n7d")

        grafana = Grafana("Grafana")

        app >> link("spans + logs") >> collector
        collector >> link("OTLP") >> tempo
        collector >> link("OTLP") >> loki
        app >> link("scrape") >> prom

        # Pushes Prometheus onto the same rank as the other two backends, which
        # would otherwise sit a column to its right.
        collector >> Edge(style="invis") >> prom

        # The three signals are cross-linked inside Grafana (exemplar to trace,
        # trace to logs). Drawing those as edges here turns a clean pipeline
        # into a knot, so they live in the README text instead.
        prom >> link("metrics") >> grafana
        tempo >> link("traces") >> grafana
        loki >> link("logs") >> grafana


if __name__ == "__main__":
    infrastructure()
    delivery()
    observability()
    print("wrote:", ", ".join(sorted(p.name for p in OUT.glob("*.png"))))
