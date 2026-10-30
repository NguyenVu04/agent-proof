# docs/architecture/deployment.py
from diagrams import Cluster, Diagram, Edge
from diagrams.generic.storage import Storage
from diagrams.onprem.compute import Server
from diagrams.onprem.container import Docker
from diagrams.onprem.database import ClickHouse, PostgreSQL
from diagrams.onprem.network import Envoy

with Diagram(
    "Deployment, local Compose stack",
    filename="images/deployment",
    outformat="png",
    show=False,
    direction="TB",
):
    with Cluster("developer machine"):
        ollama = Server("Ollama :11434")

        with Cluster("Docker Compose project: agentproof"):
            frontend = Docker("frontend :3000")
            gateway = Envoy("envoy :80")

            with Cluster("one backend image"):
                api = Docker("api :8000")
                analysis = Docker("worker-analysis")
                semantic = Docker("worker-semantic")

            with Cluster("named volumes"):
                postgres = PostgreSQL("postgres :5432")
                qdrant = Server("qdrant :6333")
                blob = Storage("seaweedfs :8333")
                clickhouse = ClickHouse("clickhouse, Phase 2")

    frontend >> gateway
    gateway >> api
    api >> postgres
    api >> blob
    postgres >> Edge(style="dashed") >> analysis
    postgres >> Edge(style="dashed") >> semantic
    analysis >> postgres
    semantic >> qdrant
    semantic >> ollama
    api >> Edge(style="dotted") >> clickhouse
