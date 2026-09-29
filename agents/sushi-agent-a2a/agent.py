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

"""sushi-agent-a2a/agent.py — Sushi Specialist (google-adk(a2a) pattern).

KEY DIFFERENCES from sushi-agent (non-A2A):
  - Uses `from google.adk.agents import Agent` (NOT GatewayAgent)
  - NO sys.path.insert — not needed, no local package imports
  - NO gateway_agent/ local package — not pickle-safe for A2A deploy
  - Deployed via scripts/deploy_a2a_agent.py with cloudpickle.register_pickle_by_value
  - deploy script wraps root_agent in A2aAgent → google-adk(a2a) in console

Tools: identical to sushi-agent — no business logic changes.
"""

import json
import logging
import os

from google.adk.agents import Agent
from google.genai import types

logger = logging.getLogger(__name__)

_PROJECT = os.environ.get("GCP_PROJECT_ID", os.environ.get("GOOGLE_CLOUD_PROJECT", "geap-agw"))

try:
    from food_court_backend import (
        place_order as _place_order,
        check_inventory as _check_inventory,
    )
    _BACKEND = True
except ImportError:
    _BACKEND = False
    logger.warning("food_court_backend not available — using simulated responses")


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

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
        roll_name: Name of the roll (e.g. 'Dragon Roll').

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
            "ingredients": "Shrimp tempura, cucumber inside; avocado, tuna on top; eel sauce",
            "allergens": "Shellfish, fish, gluten (tempura), sesame",
            "calories": "~370 kcal",
            "note": "Our most popular roll — a beautiful presentation piece.",
        },
        "rainbow roll": {
            "ingredients": "California roll base topped with sashimi: salmon, tuna, yellowtail, shrimp, avocado",
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
        return f"Details for '{roll_name}': not found. Try: California Roll, Dragon Roll, Spicy Tuna Roll."
    return json.dumps({
        "roll": roll_name,
        "ingredients": info["ingredients"],
        "allergens": info["allergens"],
        "calories": info["calories"],
        "note": info["note"],
    })


def check_nigiri_options(fish_type: str = "") -> str:
    """Check nigiri availability and freshness.

    Args:
        fish_type: Type of fish (e.g. 'salmon', 'tuna'). Leave blank for all.

    Returns:
        JSON with availability and freshness status.
    """
    availability = {
        "salmon":     ("available", "Fresh Atlantic salmon — delivered this morning"),
        "tuna":       ("available", "Premium bluefin — excellent quality today"),
        "yellowtail": ("available", "Hamachi from Japan — silky and mild"),
        "shrimp":     ("available", "Wild-caught — sweet and firm"),
        "eel":        ("available", "Freshwater unagi — pre-seasoned with our house sauce"),
        "scallop":    ("available", "Diver scallops — seared to order"),
    }
    if fish_type:
        key = fish_type.lower().strip()
        status, note = availability.get(key, ("unknown", "Please ask staff for today's availability"))
        return json.dumps({"fish": fish_type, "status": status, "note": note})

    return json.dumps({
        fish: {"status": status, "note": note}
        for fish, (status, note) in availability.items()
    })


def place_sushi_order(items: str, special_requests: str = "", customer_id: str = "guest") -> str:
    """Place a sushi order with selected items and any special requests.

    Args:
        items: Comma-separated list of items (e.g. 'Dragon Roll, Salmon Nigiri x2').
        special_requests: Any special dietary requests or modifications.
        customer_id: Customer identifier for loyalty tracking. Defaults to 'guest'.

    Returns:
        JSON order confirmation with order ID and estimated preparation time.
    """
    if _BACKEND:
        return _place_order(
            cuisine="sushi",
            items=items,
            customer_id=customer_id,
            special_requests=special_requests,
        )
    import uuid
    order_id = f"ORD-{uuid.uuid4().hex[:8].upper()}"
    return json.dumps({
        "status": "confirmed",
        "order_id": order_id,
        "cuisine": "sushi",
        "items": items,
        "special_requests": special_requests or "none",
        "prep_time_minutes": "8-12",
        "note": "Complimentary miso soup and edamame included with orders over $15.",
    })


def filter_sushi_by_diet(restriction: str) -> str:
    """Filter sushi menu items based on a dietary restriction.

    Args:
        restriction: One of: vegan, vegetarian, gluten-free, shellfish-free,
            dairy-free, nut-free, halal.

    Returns:
        JSON with matching menu items and notes.
    """
    key = restriction.lower().strip()
    diet_map = {
        "vegan": {
            "items": ["Veggie Roll (avocado, sweet potato, cucumber, asparagus)"],
            "notes": ["Request tamari soy sauce for GF+vegan option.", "Ask for no sesame seeds if sesame allergy."],
        },
        "vegetarian": {
            "items": ["Veggie Roll", "Avocado Cucumber variations (ask itamae)"],
            "notes": ["Philly Roll contains cream cheese — vegetarian but not vegan.", "Specify 'no fish' when ordering."],
        },
        "gluten-free": {
            "items": ["Salmon Nigiri", "Tuna Nigiri", "Yellowtail Nigiri", "Shrimp Nigiri",
                      "Scallop Nigiri", "Salmon Sashimi", "Tuna Sashimi", "Assorted Sashimi"],
            "notes": ["Request tamari soy sauce.", "Avoid tempura rolls (Dragon, Volcano, Veggie sweet potato).",
                      "Eel sauce may contain wheat — confirm with staff."],
        },
        "shellfish-free": {
            "items": ["Salmon Nigiri", "Tuna Nigiri", "Yellowtail Nigiri",
                      "Salmon Sashimi", "Tuna Sashimi", "Spicy Tuna Roll"],
            "notes": ["Avoid: California, Dragon, Rainbow, Spider, Volcano rolls, Shrimp Nigiri, Scallop Nigiri.",
                      "Cross-contamination risk — advise staff of allergy severity."],
        },
        "dairy-free": {
            "items": ["All items EXCEPT Philly Roll"],
            "notes": ["Traditional sushi contains no dairy.", "Avoid Philly Roll (cream cheese)."],
        },
        "nut-free": {
            "items": ["All sushi items are nut-free"],
            "notes": ["Sesame sensitivity: request 'no sesame seeds' on California, Spicy Tuna, Dragon, Veggie rolls."],
        },
        "halal": {
            "items": ["Salmon Nigiri", "Tuna Nigiri", "Yellowtail Nigiri",
                      "Salmon Sashimi", "Tuna Sashimi", "Assorted Sashimi", "Spicy Tuna Roll"],
            "notes": ["Avoid Eel Nigiri — mirin (rice wine) in sauce.",
                      "Imitation crab (California Roll surimi) may contain non-halal additives."],
        },
    }
    result = diet_map.get(key)
    if not result:
        return json.dumps({
            "error": f"Unknown restriction: '{restriction}'",
            "supported": list(diet_map.keys()),
        })
    return json.dumps({"restriction": restriction, **result})


def check_ingredient_availability(ingredient: str) -> str:
    """Check real-time availability of a specific ingredient from inventory.

    Args:
        ingredient: e.g. 'salmon', 'bluefin tuna', 'scallop', 'avocado'.

    Returns:
        JSON availability status from Firestore inventory.
    """
    if _BACKEND:
        return _check_inventory(ingredient)
    return json.dumps({
        "ingredient": ingredient,
        "status": "unknown",
        "message": f"Inventory system unavailable — please ask staff about '{ingredient}'.",
    })


# ---------------------------------------------------------------------------
# AGENT_SKILLS — used by deploy_a2a_agent.py to build the agent card.
# The deploy script reads this from the agent module.
# ---------------------------------------------------------------------------
# (imported lazily at deploy time to avoid a2a-sdk import at container startup)
AGENT_SKILLS_CONFIG = [
    {
        "id": "sushi-menu",
        "name": "Sushi Menu & Information",
        "description": "Browse sushi menu: rolls, nigiri, sashimi, specialty sets with prices",
        "tags": ["sushi", "menu", "food", "japanese"],
    },
    {
        "id": "sushi-dietary",
        "name": "Dietary & Allergen Filter",
        "description": "Filter menu by dietary restriction: vegan, gluten-free, halal, shellfish-free, etc.",
        "tags": ["dietary", "allergen", "vegan", "gluten-free", "halal"],
    },
    {
        "id": "sushi-inventory",
        "name": "Ingredient Availability",
        "description": "Real-time ingredient availability check from Firestore inventory",
        "tags": ["inventory", "availability", "fresh", "stock"],
    },
    {
        "id": "sushi-order",
        "name": "Place Sushi Order",
        "description": "Place and confirm a sushi order with Firestore persistence and order ID",
        "tags": ["order", "checkout", "purchase"],
    },
]

# ---------------------------------------------------------------------------
# Root Agent — plain ADK Agent (pickle-safe for google-adk(a2a) deployment)
# ---------------------------------------------------------------------------
root_agent = Agent(
    model="gemini-3.5-flash",
    name="sushi_specialist_a2a",
    description=(
        "Sushi Specialist A2A: expert in sushi menu, rolls, nigiri, sashimi, "
        "dietary filters, allergens, ingredient availability, and order placement. "
        "True A2A agent — discoverable via agent card in Agent Registry."
    ),
    instruction="""You are an expert sushi itamae (master chef) at a premium food court.

CAPABILITIES:
- Show the full sushi menu: rolls, nigiri, sashimi, specialty sets
- Provide detailed ingredient and allergen information for any roll
- Check nigiri freshness and availability
- Filter menu items by dietary restriction (vegan, vegetarian, gluten-free, shellfish-free, dairy-free, nut-free, halal)
- Check real-time ingredient availability from inventory
- Place and confirm orders with Firestore persistence and order ID tracking

RULES:
- Do NOT output any intermediate text before tool calls complete.
- ALWAYS call the appropriate tool first, then summarize results.
- Only output a final summary AFTER all tool results are received.
- Guide beginners gently (suggest California Roll or Salmon Nigiri to start)
- For adventurous eaters, recommend the Omakase set or Dragon Roll
- Always mention allergen info when relevant
- Use filter_sushi_by_diet when customer mentions ANY dietary restriction
- Use check_ingredient_availability to confirm fresh stock of premium items
- Confirm orders clearly including special requests and customer ID
""",
    generate_content_config=types.GenerateContentConfig(temperature=0.0),
    tools=[
        list_sushi_menu,
        get_roll_details,
        check_nigiri_options,
        place_sushi_order,
        filter_sushi_by_diet,
        check_ingredient_availability,
    ],
)
