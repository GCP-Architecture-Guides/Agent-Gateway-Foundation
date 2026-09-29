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

"""sushi-agent/agent.py — Sushi Specialist Agent.

Handles all sushi-related queries: menu browsing, roll options,
sashimi selection, nigiri choices, dietary info, and ordering.

This agent is the Phase 2 proof-of-concept for zero-touch dynamic discovery.
It is registered in the Agent Registry via labels (capability=sushi-ordering,
role=specialist) — the orchestrator discovers it automatically without any
orchestrator redeployment.
"""


import logging
import os
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
    GlobalGemini = None

_MODEL = GlobalGemini(model="gemini-3.5-flash") if GlobalGemini else "gemini-3.5-flash"

# ---------------------------------------------------------------------------
# Org Policy patch: prevent gRPC project-number → project-ID lookups.
# ---------------------------------------------------------------------------
try:
    from google.cloud.aiplatform.utils import resource_manager_utils as _rmutils
    _orig_get_project_id = _rmutils.get_project_id

    def _patched_get_project_id(project=None, **kwargs):
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
    pass  # If patch fails, proceed — may crash later in set_up()


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


def list_sushi_menu() -> str:
    """List the full sushi menu with categories, descriptions, and prices."""
    return """
🍣 SUSHI MENU — Premium Food Court

── ROLLS ──────────────────────────────────────────
1. California Roll          — crab, avocado, cucumber                    $9.99
2. Spicy Tuna Roll          — tuna, spicy mayo, cucumber                 $11.99
3. Dragon Roll              — shrimp tempura, avocado, eel sauce         $14.99
4. Rainbow Roll             — California roll topped with 5 sashimi      $16.99
5. Philly Roll              — salmon, cream cheese, cucumber             $12.99
6. Spider Roll              — soft shell crab, avocado, cucumber         $15.99
7. Volcano Roll             — shrimp tempura, spicy tuna, baked scallop  $17.99
8. Veggie Roll              — avocado, sweet potato, cucumber, asparagus  $9.99

── NIGIRI (2 pieces) ──────────────────────────────
9.  Salmon Nigiri           — fresh Atlantic salmon                       $6.99
10. Tuna Nigiri             — premium bluefin tuna                        $7.99
11. Yellowtail Nigiri       — hamachi, light and buttery                  $7.99
12. Shrimp Nigiri           — sweet boiled shrimp                         $5.99
13. Eel Nigiri (Unagi)      — freshwater eel with sweet sauce             $8.99
14. Scallop Nigiri          — seared diver scallop                        $9.99

── SASHIMI (5 pieces) ─────────────────────────────
15. Salmon Sashimi          — 5 slices fresh salmon                      $13.99
16. Tuna Sashimi            — 5 slices premium tuna                      $14.99
17. Assorted Sashimi        — chef's selection of 8 slices               $18.99

── SPECIALTY ──────────────────────────────────────
18. Omakase Set             — chef's 12-piece tasting selection           $34.99
19. Bento Box               — 4-piece nigiri + roll + miso + salad        $22.99
"""


def get_roll_details(roll_name: str) -> str:
    """Get detailed information about a specific roll including ingredients and allergens.

    Args:
        roll_name: Name of the roll to get details for (e.g. "Dragon Roll").

    Returns:
        Detailed description, ingredients, and allergen information.
    """
    rolls = {
        "california roll": {
            "ingredients": "Imitation crab (surimi), ripe avocado, cucumber, sesame seeds, nori",
            "allergens": "Shellfish (surimi), sesame",
            "calories": "~255 kcal",
            "note": "Great for sushi beginners — mild and creamy.",
        },
        "spicy tuna roll": {
            "ingredients": "Fresh tuna, sriracha mayo, cucumber, sesame seeds, nori",
            "allergens": "Fish, sesame, soy",
            "calories": "~290 kcal",
            "note": "Medium heat — ask for extra spicy mayo on the side.",
        },
        "dragon roll": {
            "ingredients": "Shrimp tempura, cucumber inside; avocado, thin-sliced tuna on top; eel sauce",
            "allergens": "Shellfish, fish, gluten (tempura), sesame",
            "calories": "~370 kcal",
            "note": "Our most popular roll — a beautiful presentation piece.",
        },
        "rainbow roll": {
            "ingredients": "California roll base topped with rotating sashimi: salmon, tuna, yellowtail, shrimp, avocado",
            "allergens": "Shellfish, fish, sesame",
            "calories": "~425 kcal",
            "note": "Instagram-worthy and a great sampler of our best fish.",
        },
        "volcano roll": {
            "ingredients": "Shrimp tempura inside; baked spicy scallop and tuna on top; eel sauce",
            "allergens": "Shellfish, fish, gluten, sesame",
            "calories": "~450 kcal",
            "note": "Served warm — our richest, most indulgent roll.",
        },
        "veggie roll": {
            "ingredients": "Avocado, sweet potato tempura, cucumber, asparagus, sesame seeds",
            "allergens": "Sesame, gluten (tempura)",
            "calories": "~200 kcal",
            "note": "100% plant-based — vegan-friendly.",
        },
    }
    key = roll_name.lower().strip()
    info = rolls.get(key)
    if not info:
        return f"Details for '{roll_name}': not found. Try 'California Roll', 'Dragon Roll', 'Spicy Tuna Roll', etc."
    return (
        f"🍱 {roll_name}\n"
        f"   Ingredients : {info['ingredients']}\n"
        f"   Allergens   : {info['allergens']}\n"
        f"   Calories    : {info['calories']}\n"
        f"   Chef's note : {info['note']}"
    )


def check_nigiri_options(fish_type: str = "") -> str:
    """Check nigiri availability and freshness for a specific fish type.

    Args:
        fish_type: Type of fish to check (e.g. "salmon", "tuna"). Leave blank for all.

    Returns:
        Availability and freshness status.
    """
    availability = {
        "salmon":    ("✅ Available", "Fresh Atlantic salmon — delivered this morning"),
        "tuna":      ("✅ Available", "Premium bluefin — excellent quality today"),
        "yellowtail":("✅ Available", "Hamachi from Japan — silky and mild"),
        "shrimp":    ("✅ Available", "Wild-caught — sweet and firm"),
        "eel":       ("✅ Available", "Freshwater unagi — pre-seasoned with our house sauce"),
        "scallop":   ("✅ Available", "Diver scallops — seared to order"),
    }

    if fish_type:
        key = fish_type.lower().strip()
        status, note = availability.get(key, ("❓ Unknown", "Please ask staff for today's availability"))
        return f"Nigiri — {fish_type.title()}: {status}\n  {note}"

    lines = ["🐟 Nigiri Availability — Today's Freshness:"]
    for fish, (status, note) in availability.items():
        lines.append(f"  {status}  {fish.title():<12} — {note}")
    return "\n".join(lines)


def place_sushi_order(items: str, special_requests: str = "", customer_id: str = "guest") -> str:
    """Place a sushi order with selected items and any special requests.

    Args:
        items: Comma-separated list of items (e.g. 'Dragon Roll, Salmon Nigiri x2').
        special_requests: Any special dietary requests or modifications.
        customer_id: Customer identifier for loyalty tracking. Defaults to 'guest'.

    Returns:
        Order confirmation with order ID and estimated preparation time.
    """
    if _BACKEND:
        return _place_order(
            cuisine='sushi',
            items=items,
            customer_id=customer_id,
            special_requests=special_requests,
        )
    # Fallback
    order_id = f'ORD-{uuid.uuid4().hex[:8].upper()}'
    return (
        f'✅ 🍣 Sushi Order Confirmed! (simulated)\n'
        f'   Order ID         : {order_id}\n'
        f'   Items            : {items}\n'
        f'   Special requests : {special_requests or "None"}\n'
        f'   Prep time        : 8–12 minutes\n'
        f'   Status           : Being prepared by our itamae (head chef)\n\n'
        f'   🍵 Complimentary miso soup and edamame included with all orders over $15.'
    )


def filter_sushi_by_diet(restriction: str) -> str:
    """Filter sushi menu items based on a dietary restriction.

    Args:
        restriction: Dietary restriction to filter by. Supported values:
            'vegan', 'vegetarian', 'gluten-free', 'shellfish-free',
            'dairy-free', 'nut-free', 'halal'.

    Returns:
        List of menu items that meet the dietary restriction with notes.
    """
    key = restriction.lower().strip()

    diet_map = {
        "vegan": (
            "🌱 Vegan Options:\n"
            "   • Veggie Roll (avocado, sweet potato, cucumber, asparagus)\n\n"
            "   Note: Ask for no sesame seeds if you have a sesame allergy.\n"
            "   Soy sauce contains wheat — request tamari for a vegan + GF option."
        ),
        "vegetarian": (
            "🥗 Vegetarian Options:\n"
            "   • Veggie Roll (avocado, sweet potato, cucumber, asparagus)\n"
            "   • Avocado Cucumber variations available — ask your itamae\n\n"
            "   Note: Cream cheese in Philly Roll is vegetarian but not vegan.\n"
            "   Specify 'no fish' when ordering to avoid cross-contamination."
        ),
        "gluten-free": (
            "🌾 Gluten-Free Options:\n"
            "   • Salmon Nigiri\n"
            "   • Tuna Nigiri\n"
            "   • Yellowtail Nigiri\n"
            "   • Shrimp Nigiri\n"
            "   • Eel Nigiri (Unagi) — check sauce ingredients with staff\n"
            "   • Scallop Nigiri\n"
            "   • Salmon Sashimi\n"
            "   • Tuna Sashimi\n"
            "   • Assorted Sashimi\n\n"
            "   ⚠️  We use GF tamari soy sauce upon request — please specify when ordering.\n"
            "   Avoid tempura rolls (Dragon, Volcano, Veggie Roll sweet potato) — contain gluten.\n"
            "   Eel sauce may contain wheat — confirm with staff for strict GF needs."
        ),
        "shellfish-free": (
            "🦐 Shellfish-Free Options:\n"
            "   • Salmon Nigiri\n"
            "   • Tuna Nigiri\n"
            "   • Yellowtail Nigiri\n"
            "   • Salmon Sashimi\n"
            "   • Tuna Sashimi\n"
            "   • Salmon Roll\n"
            "   • Tuna Roll (Spicy Tuna Roll without surimi)\n\n"
            "   ⚠️  Avoid: California Roll (surimi/imitation crab), Dragon Roll (shrimp),\n"
            "       Rainbow Roll (shrimp), Spider Roll (soft shell crab),\n"
            "       Volcano Roll (shrimp + scallop), Shrimp Nigiri, Scallop Nigiri.\n"
            "   Note: Cross-contamination risk exists in our kitchen — advise staff of allergy severity."
        ),
        "dairy-free": (
            "🥛 Dairy-Free Options:\n"
            "   • All sushi items are dairy-free EXCEPT the Philly Roll (cream cheese)\n\n"
            "   ✅ Traditional Japanese sushi contains no dairy.\n"
            "   ⚠️  Avoid: Philly Roll (salmon, cream cheese, cucumber).\n"
            "   Spicy mayo (in Spicy Tuna Roll) is typically dairy-free — confirm with staff."
        ),
        "nut-free": (
            "🥜 Nut-Free Options:\n"
            "   • All sushi items are nut-free — traditional sushi contains no tree nuts or peanuts.\n\n"
            "   ⚠️  Sesame seed note: Sesame seeds are seeds, not nuts, but individuals with\n"
            "       sesame allergies should avoid rolls topped with sesame seeds:\n"
            "       California Roll, Spicy Tuna Roll, Dragon Roll, Rainbow Roll, Veggie Roll.\n"
            "   Request 'no sesame seeds' when ordering if you have a sesame sensitivity."
        ),
        "halal": (
            "☪️  Halal Options:\n"
            "   • All fish items are halal:\n"
            "     — Salmon Nigiri, Tuna Nigiri, Yellowtail Nigiri\n"
            "     — Salmon Sashimi, Tuna Sashimi, Assorted Sashimi\n"
            "     — Spicy Tuna Roll, Salmon Roll, Tuna Roll\n\n"
            "   ✅ Traditional sushi contains no pork.\n"
            "   ⚠️  Mirin (rice wine) used in eel sauce — avoid Eel Nigiri / eel sauce items\n"
            "       if strict halal (no alcohol). Confirm with staff for your requirements.\n"
            "   ⚠️  Imitation crab (surimi) in California Roll may contain non-halal additives."
        ),
    }

    result = diet_map.get(key)
    if not result:
        supported = ", ".join(diet_map.keys())
        return (
            f"❓ Unknown dietary restriction: '{restriction}'.\n"
            f"   Supported options: {supported}."
        )
    return result


def check_ingredient_availability(ingredient: str) -> str:
    """Check real-time availability of a specific ingredient.

    Args:
        ingredient: e.g. 'salmon', 'bluefin tuna', 'scallop'.

    Returns:
        Live availability from Firestore inventory.
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


root_agent = Agent(
    name=os.environ.get("AGENT_NAME", "sushi_specialist"),
    model=_MODEL,
    description=(
        "Sushi Specialist: expert in sushi menu, roll options, nigiri, sashimi, "
        "dietary info, allergens, and ordering. Registered via capability=sushi-ordering label."
    ),
    instruction="""You are an expert sushi itamae (master chef) at a premium food court.
You have deep knowledge of our sushi menu and help customers make delicious choices.

CAPABILITIES:
- Show the full sushi menu: rolls, nigiri, sashimi, specialty sets
- Provide detailed ingredient and allergen information for any roll
- Check nigiri freshness and availability
- Filter menu items by dietary restriction (vegan, vegetarian, gluten-free, shellfish-free, dairy-free, nut-free, halal)
- Check real-time ingredient availability from our inventory system
- Place and confirm orders with Firestore persistence and order ID tracking
- Make expert recommendations based on preferences and experience level

BEHAVIOUR:
- Be calm, knowledgeable, and precise — like a true sushi master
- Guide beginners gently (suggest California Roll or Salmon Nigiri to start)
- For adventurous eaters, recommend the Omakase set or Dragon Roll
- Always mention allergen info when relevant
- Use filter_sushi_by_diet when a customer mentions any dietary restriction
- Use check_ingredient_availability to confirm fresh stock of premium items like bluefin tuna or scallop
- If asked about pizza or burgers, politely say those specialists handle those cuisines
- Confirm orders clearly, including any special requests and customer ID for loyalty tracking

You are the zero-touch discovery proof: the orchestrator found you dynamically
via the Agent Registry (capability=sushi-ordering label) without any code changes.
""",
    tools=[
        list_sushi_menu,
        get_roll_details,
        check_nigiri_options,
        place_sushi_order,
        filter_sushi_by_diet,
        check_ingredient_availability,
        check_order_status,
    ],
)
