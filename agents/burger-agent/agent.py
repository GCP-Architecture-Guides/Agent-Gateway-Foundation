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

"""burger-agent/agent.py — Burger Specialist Agent.

Handles all burger-related queries: menu, customization, dietary filters,
ingredient availability, and order placement with Firestore persistence.

New in Tier 1/2:
  - place_burger_order()            — confirmed order + Firestore write
  - filter_burger_by_diet()         — vegan/GF/halal/dairy-free/nut-free filter
  - check_ingredient_availability() — real-time inventory via Firestore
"""

import logging
import os
import uuid

from google import genai
from google.adk.agents import Agent

try:
    from google.adk.models import Gemini as _GeminiBase
except ImportError:
    _GeminiBase = None

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# GlobalGemini: routes gemini-3.5-flash through Vertex AI global endpoint.
# Regional us-east1 endpoint returns 404 for Gemini 3.x models.
# ---------------------------------------------------------------------------
if _GeminiBase is not None:
    class GlobalGemini(_GeminiBase):
        @property
        def api_client(self):
            project = (
                os.environ.get("GCP_PROJECT_ID")
                or os.environ.get("GOOGLE_CLOUD_PROJECT")
            )
            return genai.Client(vertexai=True, project=project, location="global")
else:
    GlobalGemini = None

_MODEL = GlobalGemini(model="gemini-3.5-flash") if GlobalGemini else "gemini-3.5-flash"


# ---------------------------------------------------------------------------
# Org Policy patch: prevent gRPC project-number → project-ID lookups.
# ADK's adk.py set_up() calls project_id() → get_project_id(project) where
# project is None (vertexai not initialized in RE container at startup).
# This causes AttributeError: 'NoneType' has no attribute 'project_id'.
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
except Exception:
    pass



# ---------------------------------------------------------------------------
# food_court_backend — bundled by deploy_a2a_agents.sh
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

def list_burgers() -> str:
    """List all available burgers with descriptions and prices."""
    return """
BURGER MENU:
1. Classic Smash Burger   — smashed beef, American cheese, pickles, mustard  $11.99
2. Double Stack           — double smash patty, cheddar, caramelized onion   $14.99
3. Crispy Chicken Deluxe  — fried chicken breast, coleslaw, sriracha mayo    $13.99
4. Mushroom Swiss         — beef patty, sautéed mushrooms, Swiss cheese      $13.49
5. BBQ Bacon Burger       — beef, bacon, BBQ sauce, crispy onion rings       $15.99
6. Veggie Burger          — plant-based patty, avocado, lettuce, tomato      $12.99
"""


def get_burger_options() -> str:
    """Return available burger customization options."""
    return """
BURGER OPTIONS:
Patty: Beef (standard), Plant-based (+$1.50), Double (+$3.00)
Grill: Well-done, Medium (default), Medium-rare
Bun: Brioche (default), Whole wheat, Lettuce wrap (GF)
Add-ons: Extra cheese (+$1), Bacon (+$2), Avocado (+$1.50), Fried egg (+$1.50)
Sides: Fries, Sweet potato fries (+$1), Onion rings (+$1.50), Side salad
"""


def customize_burger(burger_name: str, options: str) -> str:
    """Customize a burger with patty type, grill preference, and add-ons.

    Args:
        burger_name: Name of the burger to customize.
        options: Comma-separated list of customization options.

    Returns:
        Customization summary — call place_burger_order() to confirm.
    """
    return (
        f"🍔 Custom burger built:\n"
        f"   Burger  : {burger_name}\n"
        f"   Options : {options}\n\n"
        f"   Ready to order? Call place_burger_order() to confirm and send to kitchen."
    )


def get_nutrition_info(burger_name: str) -> str:
    """Get nutritional information for a specific burger.

    Args:
        burger_name: Name of the burger.

    Returns:
        Nutritional breakdown.
    """
    nutrition = {
        "classic smash burger": "620 cal | Protein: 34g | Fat: 38g | Carbs: 42g",
        "double stack": "890 cal | Protein: 56g | Fat: 58g | Carbs: 42g",
        "crispy chicken deluxe": "710 cal | Protein: 42g | Fat: 34g | Carbs: 58g",
        "mushroom swiss": "680 cal | Protein: 36g | Fat: 40g | Carbs: 44g",
        "bbq bacon burger": "820 cal | Protein: 48g | Fat: 50g | Carbs: 54g",
        "veggie burger": "520 cal | Protein: 22g | Fat: 26g | Carbs: 52g",
    }
    key = burger_name.lower().strip()
    return nutrition.get(key, f"Nutrition info for '{burger_name}': Please ask staff for full allergen details.")


# ---------------------------------------------------------------------------
# Tier 1: place_burger_order
# ---------------------------------------------------------------------------

def place_burger_order(
    items: str,
    options: str = "",
    special_requests: str = "",
    customer_id: str = "guest",
) -> str:
    """Place and confirm a burger order. Sends order to kitchen with Firestore persistence.

    Args:
        items: Burger name(s) to order, e.g. "Classic Smash Burger" or "Veggie Burger x2".
        options: Customization options, e.g. "plant-based patty, no cheese, lettuce wrap".
        special_requests: Any special instructions, e.g. "extra crispy", "no pickles".
        customer_id: Customer identifier for loyalty tracking. Defaults to "guest".

    Returns:
        Order confirmation with order ID and estimated prep time.
    """
    full_items = items
    if options:
        full_items = f"{items} ({options})"

    if _BACKEND:
        return _place_order(
            cuisine="burger",
            items=full_items,
            customer_id=customer_id,
            special_requests=special_requests,
        )
    order_id = f"ORD-{uuid.uuid4().hex[:8].upper()}"
    return (
        f"✅ 🍔 Burger Order Confirmed! (simulated)\n"
        f"   Order ID         : {order_id}\n"
        f"   Items            : {full_items}\n"
        f"   Special requests : {special_requests or 'None'}\n"
        f"   Estimated time   : 10–15 minutes\n"
        f"   Status           : Sent to kitchen 👨\u200d🍳"
    )


# ---------------------------------------------------------------------------
# Tier 1: filter_burger_by_diet
# ---------------------------------------------------------------------------

def filter_burger_by_diet(restriction: str) -> str:
    """Filter the burger menu by a dietary restriction.

    Args:
        restriction: One of: vegan, vegetarian, gluten-free, dairy-free,
                     nut-free, halal, pork-free, low-calorie.

    Returns:
        List of suitable burgers with modification notes.
    """
    key = restriction.lower().strip()

    filters: dict[str, tuple[str, list[str]]] = {
        "vegan": (
            "🌱 Vegan options:",
            [
                "✅ Veggie Burger — order with plant-based patty, lettuce wrap bun, no mayo",
                "   Ask for avocado and extra tomato — fully plant-based.",
            ],
        ),
        "vegetarian": (
            "🥦 Vegetarian options (no meat):",
            [
                "✅ Veggie Burger — plant-based patty (default or upgrade to double)",
                "   Any burger can use plant-based patty (+$1.50).",
            ],
        ),
        "gluten-free": (
            "🌾 Gluten-free options (choose lettuce wrap bun):",
            [
                "✅ Any burger with lettuce wrap (no brioche/whole wheat bun)",
                "✅ Skip onion rings side (battered) — choose fries or side salad",
                "   Note: Prepared in a shared kitchen — traces possible.",
            ],
        ),
        "dairy-free": (
            "🥛 Dairy-free options (no cheese):",
            [
                "✅ Classic Smash Burger — no cheese, no mayo",
                "✅ BBQ Bacon Burger — no bacon-cheese sauce (ask for plain BBQ)",
                "✅ Crispy Chicken Deluxe — sriracha mayo is dairy-free",
                "✅ Veggie Burger — no cheese",
                "❌ Mushroom Swiss — Swiss cheese is integral to the burger",
            ],
        ),
        "nut-free": (
            "🥜 Nut-free options (no nuts in any of our burgers):",
            [
                "✅ All burgers are nut-free",
                "   Note: Kitchen handles tree nuts in other items — advise staff of severe allergy.",
            ],
        ),
        "halal": (
            "☪️  Halal options (no pork, halal-certified beef and chicken):",
            [
                "✅ Classic Smash Burger — halal beef",
                "✅ Double Stack — halal beef",
                "✅ Crispy Chicken Deluxe — halal chicken",
                "✅ Mushroom Swiss — halal beef",
                "✅ Veggie Burger",
                "❌ BBQ Bacon Burger — contains pork bacon",
            ],
        ),
        "pork-free": (
            "🚫 Pork-free options:",
            [
                "✅ Classic Smash Burger",
                "✅ Double Stack",
                "✅ Crispy Chicken Deluxe",
                "✅ Mushroom Swiss",
                "✅ Veggie Burger",
                "❌ BBQ Bacon Burger — pork bacon",
            ],
        ),
        "low-calorie": (
            "🥗 Lower-calorie options (under 600 cal):",
            [
                "✅ Veggie Burger — 520 cal (lettuce wrap saves ~100 cal vs brioche)",
                "✅ Classic Smash Burger — 620 cal (no cheese saves ~80 cal)",
                "   Choose side salad instead of fries for biggest calorie saving.",
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
        ingredient: Ingredient name, e.g. "avocado", "bacon", "plant-based patty".

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
    name=os.environ.get("AGENT_NAME", "burger_specialist"),
    model=_MODEL,
    description="Burger Specialist: menu, patty options, dietary filters, ingredient availability, and order placement with Firestore persistence.",
    instruction="""You are an expert burger specialist at a premium food court.
You help customers choose and customize their perfect burger.

CAPABILITIES:
- Show the full burger menu with prices
- Explain patty types, grill options, bun choices, and add-ons
- Help customers customize their burger
- Provide nutritional information for any burger
- Filter menu by dietary restrictions (vegan, vegetarian, gluten-free, dairy-free, halal, pork-free, low-calorie)
- Check if specific ingredients are in stock today
- Place confirmed orders that go directly to the kitchen

ORDER FLOW:
1. Help customer choose burger + customizations
2. Confirm their choices back to them
3. Ask for customer_id (optional — for loyalty points)
4. Call place_burger_order() to confirm and send to kitchen
5. Share the Order ID with the customer

BEHAVIOUR:
- Be enthusiastic and knowledgeable about burgers
- Always ask about dietary preferences or restrictions proactively
- If a customer asks about pizza or sushi, say those specialists handle those cuisines
- Always confirm orders clearly with the Order ID
""",
    tools=[
        list_burgers,
        get_burger_options,
        customize_burger,
        get_nutrition_info,
        place_burger_order,
        filter_burger_by_diet,
        check_ingredient_availability,
        check_order_status,
    ],
)
