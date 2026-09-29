# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# This code is for PoC environment only.
# This demo code is not built for production workload.

"""pizza-agent/agent.py — Pizza Specialist Agent.

Handles all pizza-related queries: menu, customization, dietary filters,
ingredient availability, and order placement with Firestore persistence.

New in Tier 1/2:
  - place_pizza_order()             — confirmed order + Firestore write
  - filter_pizza_by_diet()          — vegan/GF/halal/dairy-free/nut-free filter
  - check_ingredient_availability() — real-time inventory via Firestore
"""

import json
import logging
import os
import time
import uuid

from google import genai
from google.adk.agents import Agent

# Try to import Gemini model class (preferred)
try:
    from google.adk.models import Gemini as _GeminiBase
except ImportError:
    _GeminiBase = None

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# GlobalGemini: routes Gemini 3.x inference through the Vertex AI global
# endpoint (aiplatform.googleapis.com). Required for gemini-3.5-flash which
# is not available at regional us-east1 endpoints (returns 404 otherwise).
# Validated working: charter-poc-test, 2026-08-08, 6/6 E2E tests passed.
# MA egress policy must use suffix rule only (no exact aiplatform match).
# ---------------------------------------------------------------------------
if _GeminiBase is not None:
    class GlobalGemini(_GeminiBase):
        """Drop-in replacement for Gemini() that forces location='global'."""
        @property
        def api_client(self):
            project = (
                os.environ.get("GCP_PROJECT_ID")
                or os.environ.get("GOOGLE_CLOUD_PROJECT")
            )
            return genai.Client(vertexai=True, project=project, location="global")
else:
    # Fallback: use plain string model name (will attempt regional, may 404)
    GlobalGemini = None

_MODEL = GlobalGemini(model="gemini-3.5-flash") if GlobalGemini else "gemini-3.5-flash"

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Org Policy patch: prevent gRPC project-number → project-ID lookups.
# ADK's adk.py set_up() calls project_id() → get_project_id(project) where
# project is None (vertexai not initialized in RE container at startup).
# This causes AttributeError: 'NoneType' has no attribute 'project_id'.
# Patch reads GCP_PROJECT_ID (non-reserved env var we inject via env_vars)
# or falls back to GOOGLE_CLOUD_PROJECT (reserved, auto-set by platform).
# Must be applied before AgentEngine framework calls set_up().
# ---------------------------------------------------------------------------
try:
    from google.cloud.aiplatform.utils import resource_manager_utils as _rmutils
    _orig_get_project_id = _rmutils.get_project_id

    def _patched_get_project_id(project):
        if project is not None:
            try:
                return _orig_get_project_id(project)
            except Exception:
                pass
        return (
            os.environ.get("GCP_PROJECT_ID")
            or os.environ.get("GOOGLE_CLOUD_PROJECT")
            or ""
        )

    _rmutils.get_project_id = _patched_get_project_id
except Exception as _patch_err:
    pass  # If patch fails, proceed — may crash later in set_up()



# ---------------------------------------------------------------------------
# food_court_backend — bundled by deploy_a2a_agents.sh alongside gateway_agent.
# Graceful fallback: if not present (local dev without bundle), order
# persistence is disabled but agent still works.
# ---------------------------------------------------------------------------
try:
    from food_court_backend import (
        place_order as _place_order,
        check_inventory as _check_inventory,
        get_order_status as _get_order_status,
    )
    _BACKEND = True
except ImportError:
    _BACKEND = False
    logger.warning("food_court_backend not available — using simulated responses")


# ---------------------------------------------------------------------------
# Menu tools
# ---------------------------------------------------------------------------

def list_pizzas() -> str:
    """List all available pizzas on the menu with descriptions and prices."""
    return """
PIZZA MENU:
1. Margherita Classic     — tomato, mozzarella, basil        $12.99
2. Pepperoni Supreme      — pepperoni, extra mozzarella       $14.99
3. BBQ Chicken            — BBQ sauce, chicken, red onion     $15.99
4. Veggie Delight         — roasted veggies, feta, olives     $13.99
5. Meat Lovers            — pepperoni, sausage, bacon, ham    $16.99
6. Truffle Mushroom       — truffle oil, mushrooms, parmesan  $17.99
"""


def get_pizza_sizes() -> str:
    """Return available pizza sizes and price adjustments."""
    return """
PIZZA SIZES:
- Personal (8"):  base price − $3
- Medium (12"):   base price (standard)
- Large (16"):    base price + $4
- XL (18"):       base price + $7
"""


def customize_pizza(pizza_name: str, toppings: str, size: str) -> str:
    """Customize a pizza with additional toppings and size selection.

    Args:
        pizza_name: Name of the pizza to customize.
        toppings: Comma-separated list of additional toppings to add.
        size: Size of the pizza (Personal/Medium/Large/XL).

    Returns:
        Customization summary — call place_pizza_order() to confirm.
    """
    return (
        f"🍕 Custom pizza built:\n"
        f"   Pizza  : {pizza_name}\n"
        f"   Size   : {size}\n"
        f"   Extras : {toppings}\n\n"
        f"   Ready to order? Call place_pizza_order() to confirm and send to kitchen."
    )


def get_pizza_ingredients(pizza_name: str) -> str:
    """Get the detailed ingredients list for a specific pizza.

    Args:
        pizza_name: Name of the pizza to get ingredients for.

    Returns:
        Detailed ingredients list.
    """
    ingredients = {
        "margherita classic": "San Marzano tomatoes, fresh mozzarella di bufala, fresh basil, extra virgin olive oil, sea salt",
        "pepperoni supreme": "Tomato sauce, shredded mozzarella, premium pepperoni, oregano",
        "bbq chicken": "Smoky BBQ sauce, grilled chicken breast, red onion, cilantro, mozzarella",
        "veggie delight": "Tomato sauce, zucchini, bell peppers, kalamata olives, feta, fresh basil",
        "meat lovers": "Tomato sauce, mozzarella, pepperoni, Italian sausage, bacon, ham",
        "truffle mushroom": "White truffle oil, cremini mushrooms, parmesan, thyme, garlic",
    }
    key = pizza_name.lower().strip()
    return ingredients.get(key, f"Ingredients for '{pizza_name}': Please ask staff for allergen details.")


# ---------------------------------------------------------------------------
# Tier 1: place_pizza_order
# ---------------------------------------------------------------------------

def place_pizza_order(
    items: str,
    size: str = "Medium",
    special_requests: str = "",
    customer_id: str = "guest",
) -> str:
    """Place and confirm a pizza order. Sends order to kitchen with Firestore persistence.

    Args:
        items: Pizza name(s) to order, e.g. "Pepperoni Supreme" or "Margherita + Veggie Delight".
        size: Pizza size — Personal / Medium (default) / Large / XL.
        special_requests: Any special instructions, e.g. "extra crispy", "no onions", "vegan cheese".
        customer_id: Customer identifier for loyalty tracking. Defaults to "guest".

    Returns:
        Order confirmation with order ID and estimated prep time.
    """
    if _BACKEND:
        return _place_order(
            cuisine="pizza",
            items=items,
            customer_id=customer_id,
            size=size,
            special_requests=special_requests,
        )
    # Fallback (local dev / backend unavailable)
    order_id = f"ORD-{uuid.uuid4().hex[:8].upper()}"
    return (
        f"✅ 🍕 Pizza Order Confirmed! (simulated)\n"
        f"   Order ID         : {order_id}\n"
        f"   Items            : {items}\n"
        f"   Size             : {size}\n"
        f"   Special requests : {special_requests or 'None'}\n"
        f"   Estimated time   : 15–20 minutes\n"
        f"   Status           : Sent to kitchen 👨\u200d🍳"
    )


# ---------------------------------------------------------------------------
# Tier 1: filter_pizza_by_diet
# ---------------------------------------------------------------------------

def filter_pizza_by_diet(restriction: str) -> str:
    """Filter the pizza menu by a dietary restriction.

    Args:
        restriction: One of: vegan, vegetarian, gluten-free, dairy-free,
                     nut-free, halal, pork-free.

    Returns:
        List of suitable pizzas with modification notes.
    """
    key = restriction.lower().strip()

    filters: dict[str, tuple[str, list[str]]] = {
        "vegan": (
            "🌱 Vegan options (ask for vegan cheese + no egg wash on crust):",
            [
                "✅ Veggie Delight — ask for vegan feta substitute",
                "✅ Margherita Classic — ask for vegan mozzarella",
                "✅ Truffle Mushroom — ask for dairy-free parmesan",
            ],
        ),
        "vegetarian": (
            "🥦 Vegetarian options (no meat):",
            [
                "✅ Margherita Classic",
                "✅ Veggie Delight",
                "✅ Truffle Mushroom",
            ],
        ),
        "gluten-free": (
            "🌾 Gluten-free options (GF crust available on request, +$2.50):",
            [
                "✅ Any pizza on the menu — just request a gluten-free base",
                "   Note: Prepared in a shared kitchen — traces possible.",
            ],
        ),
        "dairy-free": (
            "🥛 Dairy-free options (ask for no cheese or dairy-free substitute):",
            [
                "✅ Veggie Delight — no feta or swap dairy-free",
                "✅ BBQ Chicken — no mozzarella or swap dairy-free",
                "✅ Margherita Classic — dairy-free mozzarella available",
            ],
        ),
        "nut-free": (
            "🥜 Nut-free options (no nuts in any of our pizzas):",
            [
                "✅ All pizzas are nut-free",
                "   Note: Kitchen handles tree nuts — advise staff of severe allergy.",
            ],
        ),
        "halal": (
            "☪️  Halal options (no pork, alcohol-free):",
            [
                "✅ Margherita Classic",
                "✅ BBQ Chicken — chicken is halal-certified",
                "✅ Veggie Delight",
                "✅ Truffle Mushroom",
                "❌ Pepperoni Supreme — contains pork pepperoni",
                "❌ Meat Lovers — contains pork (bacon, sausage)",
            ],
        ),
        "pork-free": (
            "🚫 Pork-free options:",
            [
                "✅ Margherita Classic",
                "✅ BBQ Chicken",
                "✅ Veggie Delight",
                "✅ Truffle Mushroom",
                "❌ Pepperoni Supreme — pork pepperoni",
                "❌ Meat Lovers — pork sausage and bacon",
            ],
        ),
    }

    if key not in filters:
        available = ", ".join(filters.keys())
        return f"Unknown dietary filter '{restriction}'. Available filters: {available}"

    header, items_list = filters[key]
    lines = [header] + [f"  {item}" for item in items_list]
    lines.append("\n  Mention your dietary requirement when placing your order.")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Tier 2: check_ingredient_availability
# ---------------------------------------------------------------------------

def check_ingredient_availability(ingredient: str) -> str:
    """Check real-time availability of a specific ingredient from kitchen inventory.

    Args:
        ingredient: Ingredient name, e.g. "truffle oil", "mozzarella", "pepperoni".

    Returns:
        Live availability status from Firestore inventory.
    """
    if _BACKEND:
        return _check_inventory(ingredient)
    return f"Inventory check unavailable — please ask our staff about '{ingredient}'."


# ---------------------------------------------------------------------------
# check_order_status — live order tracking
# ---------------------------------------------------------------------------

def check_order_status(order_id: str) -> str:
    """Check the live status of an existing order using its Order ID.

    Args:
        order_id: The Order ID returned when the order was placed (e.g. ORD-ABC12345).

    Returns:
        Current order status: RECEIVED, PREPARING, ALMOST READY, or READY.
    """
    if _BACKEND:
        return _get_order_status(order_id)
    return (
        f"Order tracking unavailable offline.\n"
        f"Your order '{order_id}' was confirmed — please check with kitchen staff."
    )


# ---------------------------------------------------------------------------
# Root agent
# ---------------------------------------------------------------------------

root_agent = Agent(
    name=os.environ.get("AGENT_NAME", "pizza_specialist"),
    model=_MODEL,
    description="Pizza Specialist: menu, customization, dietary filters, ingredient availability, and order placement with Firestore persistence.",
    instruction="""You are an enthusiastic pizza specialist at a premium food court.
You know everything about our pizza menu and help customers make delicious choices.

CAPABILITIES:
- Show the full pizza menu with prices
- Explain available sizes and price differences
- Help customers customize their pizza with extra toppings
- Provide detailed ingredient information for any pizza
- Filter menu by dietary restrictions (vegan, gluten-free, halal, dairy-free, nut-free, pork-free)
- Check if specific ingredients are in stock today
- Place confirmed orders that go directly to the kitchen

ORDER FLOW:
1. Help customer choose pizza + size + any extras
2. Confirm their choices back to them
3. Ask for customer_id (optional — for loyalty points)
4. Call place_pizza_order() to confirm and send to kitchen
5. Share the Order ID with the customer

BEHAVIOUR:
- Be warm, enthusiastic, and knowledgeable about pizza
- Always ask about dietary restrictions proactively
- If a customer asks about burgers or sushi, say those specialists handle those cuisines
- Always confirm orders clearly with the Order ID
""",
    tools=[
        list_pizzas,
        get_pizza_sizes,
        customize_pizza,
        get_pizza_ingredients,
        place_pizza_order,
        filter_pizza_by_diet,
        check_ingredient_availability,
        check_order_status,
    ],
)
