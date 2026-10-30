# docs/architecture/overall.py
from diagrams import Cluster, Diagram, Edge
from diagrams.generic.storage import Storage
from diagrams.onprem.client import Users
from diagrams.onprem.compute import Server
from diagrams.onprem.database import ClickHouse, PostgreSQL
from diagrams.onprem.network import Envoy
from diagrams.programming.framework import FastAPI, Nextjs
from diagrams.programming.language import Python

with Diagram(
    "Overall architecture",
    filename="images/overall",
    outformat="png",
    show=False,
    direction="LR",
    graph_attr={"splines": "spline", "nodesep": "0.7", "ranksep": "1.4"},
):
    browser = Users("browser")
    client = Server("CI client")
    agent = Server("agent, Collector")
    frontend = Nextjs("frontend")
    gateway = Envoy("Envoy\nAPI gateway")

    with Cluster("one backend image"):
        api = FastAPI("api")
        analysis = Python("worker-analysis")
        semantic = Python("worker-semantic")

    with Cluster("state"):
        postgres = PostgreSQL("PostgreSQL\nauthoritative, job queue")
        blob = Storage("SeaweedFS\nblob store")
        qdrant = Server("Qdrant\nprojection")
        clickhouse = ClickHouse("ClickHouse\nPhase 2")

    ollama = Server("Ollama\non host")

    browser >> Edge(label="UI, /api") >> frontend
    frontend >> Edge(label="/api rewrite") >> gateway
    client >> Edge(label="REST") >> gateway
    agent >> Edge(label="OTLP") >> gateway
    gateway >> api

    api >> postgres
    api >> blob
    postgres >> Edge(style="dashed", label="jobs") >> analysis
    postgres >> Edge(style="dashed", label="jobs") >> semantic
    analysis >> postgres
    analysis >> blob
    semantic >> qdrant
    semantic >> ollama
    api >> Edge(style="dotted") >> clickhouse
