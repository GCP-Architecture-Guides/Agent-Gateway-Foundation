"""GlobalGemini: Thin wrapper over Gemini for Agent Gateway deployments.

In ADK 1.31.1, the base Gemini class derives its endpoint from the
GOOGLE_CLOUD_LOCATION environment variable. When the RE is deployed in
us-east1, the default endpoint is us-east1-aiplatform.googleapis.com,
which is correctly routed through the Agent Gateway egress PSC.

History:
  - Originally overrode _get_client_args() to force location="global".
    This was dead code in ADK 1.31.1 (method is not called by the base class).
  - Then overrode api_client property to return Client(location="global").
    This broke egress PSC routing because the global endpoint
    (aiplatform.googleapis.com) is not reachable via the regional PSC attachment.
  - Confirmed that gemini-2.5-flash IS available at us-east1 regional endpoint.
    The original concern (model-not-found at regional) no longer applies.

Current approach: use the default Gemini api_client (regional endpoint).
The Model Armor false-positive is fixed separately by removing
response_template_id from the authz extension (see 03_security_and_gateways.tf).

If Gemini 3.x models are introduced that require the global endpoint AND
the AGW egress PSC is updated to support it, restore the api_client override:

    @property
    def api_client(self):
        from google.genai import Client
        project = os.environ.get("GCP_PROJECT_ID") or os.environ.get("GOOGLE_CLOUD_PROJECT")
        return Client(vertexai=True, project=project, location="global")
"""

from google.adk.models.google_llm import Gemini


class GlobalGemini(Gemini):
    """Drop-in replacement for Gemini() for Agent Gateway deployments.

    Currently identical to Gemini() — uses the default regional ADK endpoint
    which works with the Agent Gateway egress PSC.

    Usage:
        from gateway_agent import GlobalGemini
        model = GlobalGemini(model="gemini-2.5-flash")
    """
    # No overrides needed — base Gemini class handles endpoint routing correctly
    # for regionally-deployed Reasoning Engines via GOOGLE_CLOUD_LOCATION env var.
    pass
