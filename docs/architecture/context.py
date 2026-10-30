# docs/architecture/context.py
from diagrams import Cluster, Diagram, Edge
from diagrams.onprem.ci import GithubActions
from diagrams.onprem.client import Users
from diagrams.onprem.compute import Server
from diagrams.programming.language import Go

with Diagram(
    "System context",
    filename="images/context",
    outformat="png",
    show=False,
    direction="LR",
):
    people = Users("project members")
    agent = Server("customer agent or OTel Collector")
    ci = GithubActions("customer CI")
    cli = Go("agentproof CLI")

    with Cluster("AgentProof"):
        system = Server("AgentProof")

    auth0 = Server("Auth0")
    ollama = Server("Ollama (host)")

    people >> Edge(label="browser, OIDC") >> system
    agent >> Edge(label="OTLP spans") >> system
    ci >> Edge(label="runs") >> cli
    cli >> Edge(label="create, finalize, read gate") >> system
    ci >> Edge(label="runs cases, OTLP spans", style="dashed") >> agent
    system >> Edge(label="token keys") >> auth0
    system >> Edge(label="critic and embedding calls") >> ollama
