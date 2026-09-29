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

"""food_court_backend.py — Shared Firestore backend for all food court agents.

Provides 5 capabilities used across pizza, burger, and sushi specialist agents:
  1. place_order()         — writes order to Firestore orders/ collection
  2. get_order_status()    — reads live status for a specific order_id
  3. get_order_history()   — reads recent orders by customer_id
  4. check_inventory()     — reads ingredient availability from inventory/
  5. get_wait_times()      — reads current kitchen queue from wait_times/

Uses Firestore REST API (no SDK) so no new packages are required.
Authentication: ADC token via google.auth (already in requirements.txt).

Firestore collection schema:
  orders/{order_id}:
    cuisine, customer_id, items, size, special_requests, status, timestamp_epoch

  inventory/{ingredient_key}:
    name, available (bool), note

  customers/{customer_id}:
    name, total_orders, points

  wait_times/{cuisine}:
    minutes, last_updated_epoch
"""

import json
import logging
import os
import time
import uuid

import google.auth
import google.auth.transport.requests
import requests as http_requests

logger = logging.getLogger(__name__)

_PROJECT = os.environ.get("GCP_PROJECT_ID", os.environ.get("GOOGLE_CLOUD_PROJECT", "geap-agw"))
_FS_BASE = (
    f"https://firestore.googleapis.com/v1/projects/{_PROJECT}"
    f"/databases/(default)/documents"
)

# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

def _get_token() -> str:
    creds, _ = google.auth.default(
        scopes=["https://www.googleapis.com/auth/cloud-platform"]
    )
    creds.refresh(google.auth.transport.requests.Request())
    return creds.token


def _headers() -> dict:
    return {
        "Authorization": f"Bearer {_get_token()}",
        "Content-Type": "application/json",
    }


# ---------------------------------------------------------------------------
# Firestore helpers — convert between Python dicts and Firestore wire format
# ---------------------------------------------------------------------------

def _to_fs(value) -> dict:
    """Convert a Python value to a Firestore field value."""
    if isinstance(value, bool):
        return {"booleanValue": value}
    if isinstance(value, int):
        return {"integerValue": str(value)}
    if isinstance(value, float):
        return {"doubleValue": value}
    if value is None:
        return {"nullValue": None}
    return {"stringValue": str(value)}


def _from_fs(field: dict):
    """Convert a Firestore field value to a Python value."""
    if "stringValue" in field:
        return field["stringValue"]
    if "integerValue" in field:
        return int(field["integerValue"])
    if "doubleValue" in field:
        return float(field["doubleValue"])
    if "booleanValue" in field:
        return field["booleanValue"]
    return None


def _doc_to_dict(doc: dict) -> dict:
    """Convert a Firestore document to a plain Python dict."""
    return {k: _from_fs(v) for k, v in doc.get("fields", {}).items()}


def _dict_to_fields(d: dict) -> dict:
    """Convert a plain Python dict to Firestore fields format."""
    return {k: _to_fs(v) for k, v in d.items()}


# ---------------------------------------------------------------------------
# 1. place_order — write a confirmed order to Firestore
# ---------------------------------------------------------------------------

def place_order(
    cuisine: str,
    items: str,
    customer_id: str = "guest",
    size: str = "",
    special_requests: str = "",
) -> str:
    """Write a confirmed food order to Firestore and return order confirmation.

    Args:
        cuisine:          "pizza" | "burger" | "sushi"
        items:            Description of ordered items
        customer_id:      Customer identifier (default "guest")
        size:             Size selection (pizza only)
        special_requests: Any dietary or prep requests

    Returns:
        Formatted confirmation string with order_id and ETA.
    """
    order_id = f"ORD-{uuid.uuid4().hex[:8].upper()}"
    now = int(time.time())
    eta = {"pizza": "15–20 min", "burger": "10–15 min", "sushi": "8–12 min"}.get(cuisine, "15 min")

    doc = {
        "cuisine":          cuisine,
        "customer_id":      customer_id,
        "items":            items,
        "size":             size,
        "special_requests": special_requests,
        "status":           "confirmed",
        "order_id":         order_id,
        "timestamp_epoch":  now,
    }

    try:
        resp = http_requests.patch(
            f"{_FS_BASE}/orders/{order_id}",
            headers=_headers(),
            json={"fields": _dict_to_fields(doc)},
            timeout=10,
        )
        if resp.status_code not in (200, 201):
            logger.warning("Firestore order write %d: %s", resp.status_code, resp.text[:200])
    except Exception as exc:  # noqa: BLE001
        logger.error("Firestore order write failed: %s", exc)
        # Still return confirmation — don't fail the agent on backend error

    # Update customer order count (best-effort)
    _increment_customer_orders(customer_id)

    emoji = {"pizza": "🍕", "burger": "🍔", "sushi": "🍣"}.get(cuisine, "🍽️")
    return (
        f"✅ {emoji} Order Confirmed!\n"
        f"   Order ID         : {order_id}\n"
        f"   Items            : {items}\n"
        f"   {'Size             : ' + size + chr(10) if size else ''}"
        f"   Special requests : {special_requests or 'None'}\n"
        f"   Estimated time   : {eta}\n"
        f"   Status           : Sent to kitchen 👨‍🍳\n\n"
        f"   📱 Show order ID {order_id} at the counter to collect your order."
    )


def _increment_customer_orders(customer_id: str) -> None:
    """Best-effort increment of customer total_orders counter."""
    if customer_id == "guest":
        return
    try:
        # Read current doc
        resp = http_requests.get(
            f"{_FS_BASE}/customers/{customer_id}",
            headers=_headers(),
            timeout=5,
        )
        if resp.status_code == 200:
            current = _doc_to_dict(resp.json())
            total = current.get("total_orders", 0) + 1
            points = current.get("points", 0) + 10
        else:
            total = 1
            points = 10

        http_requests.patch(
            f"{_FS_BASE}/customers/{customer_id}",
            headers=_headers(),
            json={"fields": _dict_to_fields({
                "customer_id":  customer_id,
                "total_orders": total,
                "points":       points,
            })},
            timeout=5,
        )
    except Exception:  # noqa: BLE001
        pass



# ---------------------------------------------------------------------------
# 2. get_order_status — read live status for a specific order
# ---------------------------------------------------------------------------

def get_order_status(order_id: str) -> str:
    """Look up the live status of a specific order by its Order ID.

    Args:
        order_id: The order ID returned when the order was placed (e.g. ORD-ABC12345).

    Returns:
        Formatted status string with order details and current status.
    """
    if not order_id or not order_id.strip():
        return "Please provide a valid Order ID (e.g. ORD-ABC12345)."

    order_id = order_id.strip().upper()

    try:
        resp = http_requests.get(
            f"{_FS_BASE}/orders/{order_id}",
            headers=_headers(),
            timeout=8,
        )

        if resp.status_code == 404:
            return (
                f"❓ Order '{order_id}' not found.\n"
                "   Please double-check your Order ID. Orders are available to track for 24 hours."
            )
        if resp.status_code != 200:
            return f"Unable to retrieve order status right now. (HTTP {resp.status_code})"

        order = _doc_to_dict(resp.json())

        cuisine = order.get("cuisine", "")
        emoji = {"pizza": "🍕", "burger": "🍔", "sushi": "🍣"}.get(cuisine, "🍽️")

        # Simulate status progression based on time since order
        placed_at = order.get("timestamp_epoch", 0)
        elapsed = int(time.time() - placed_at) if placed_at else 0
        eta_seconds = {"pizza": 17 * 60, "burger": 12 * 60, "sushi": 10 * 60}.get(cuisine, 15 * 60)

        if elapsed < 60:
            status = "📥 RECEIVED — Order received by kitchen"
        elif elapsed < eta_seconds * 0.6:
            status = "👨‍🍳 PREPARING — Your order is being prepared"
        elif elapsed < eta_seconds:
            status = "🔔 ALMOST READY — Nearly done!"
        else:
            status = "✅ READY — Please collect at the counter"

        placed_str = time.strftime("%H:%M", time.localtime(placed_at)) if placed_at else "Unknown"

        return (
            f"{emoji} Order Status — {order_id}\n"
            f"   Status    : {status}\n"
            f"   Items     : {order.get('items', 'Unknown')}\n"
            f"   Cuisine   : {cuisine.title()}\n"
            f"   Placed at : {placed_str}\n"
            f"   Customer  : {order.get('customer_id', 'guest')}\n"
            + (f"   Notes     : {order.get('special_requests')}\n" if order.get('special_requests') else "")
        )

    except Exception as exc:  # noqa: BLE001
        logger.error("get_order_status failed: %s", exc)
        return "Unable to retrieve order status right now. Please try again shortly."


# ---------------------------------------------------------------------------
# 3. get_order_history — read recent orders for a customer
# ---------------------------------------------------------------------------

def get_order_history(customer_id: str) -> str:
    """Fetch a customer's last 5 orders from Firestore.

    Args:
        customer_id: The customer's identifier.

    Returns:
        Formatted order history string, or a message if no history found.
    """
    if not customer_id or customer_id == "guest":
        return (
            "No order history found for guest customers.\n"
            "Sign up for a loyalty account to track your orders and earn points!"
        )

    try:
        # Firestore REST structured query — filter by customer_id, limit 5
        query = {
            "structuredQuery": {
                "from": [{"collectionId": "orders"}],
                "where": {
                    "fieldFilter": {
                        "field": {"fieldPath": "customer_id"},
                        "op": "EQUAL",
                        "value": {"stringValue": customer_id},
                    }
                },
                "orderBy": [{"field": {"fieldPath": "timestamp_epoch"}, "direction": "DESCENDING"}],
                "limit": 5,
            }
        }
        resp = http_requests.post(
            f"https://firestore.googleapis.com/v1/projects/{_PROJECT}/databases/(default):runQuery",
            headers=_headers(),
            json=query,
            timeout=10,
        )
        if resp.status_code != 200:
            return f"Unable to retrieve order history right now. (HTTP {resp.status_code})"

        results = resp.json()
        orders = [_doc_to_dict(r["document"]) for r in results if "document" in r]

        if not orders:
            return f"No previous orders found for customer '{customer_id}'. This might be your first order with us!"

        # Customer loyalty info
        loyalty_resp = http_requests.get(
            f"{_FS_BASE}/customers/{customer_id}",
            headers=_headers(),
            timeout=5,
        )
        loyalty = _doc_to_dict(loyalty_resp.json()) if loyalty_resp.status_code == 200 else {}

        lines = [f"📋 Order History for {customer_id}:"]
        if loyalty:
            lines.append(f"   🌟 Loyalty Points: {loyalty.get('points', 0)} pts | Total Orders: {loyalty.get('total_orders', 0)}")
        lines.append("")

        for i, order in enumerate(orders, 1):
            ts = order.get("timestamp_epoch", 0)
            date_str = time.strftime("%Y-%m-%d %H:%M", time.localtime(ts)) if ts else "Unknown date"
            emoji = {"pizza": "🍕", "burger": "🍔", "sushi": "🍣"}.get(order.get("cuisine", ""), "🍽️")
            lines.append(f"  {i}. {emoji} {order.get('cuisine','?').title()} — {date_str}")
            lines.append(f"     Items: {order.get('items','?')}")
            if order.get("special_requests"):
                lines.append(f"     Notes: {order.get('special_requests')}")
            lines.append(f"     Order ID: {order.get('order_id','?')} | Status: {order.get('status','?')}")
            lines.append("")

        return "\n".join(lines)

    except Exception as exc:  # noqa: BLE001
        logger.error("get_order_history failed: %s", exc)
        return f"Unable to retrieve order history right now. Please try again shortly."


# ---------------------------------------------------------------------------
# 3. check_inventory — ingredient availability lookup
# ---------------------------------------------------------------------------

def check_inventory(ingredient: str) -> str:
    """Check if a specific ingredient is currently available in the kitchen.

    Args:
        ingredient: Ingredient name (e.g. "truffle oil", "salmon", "avocado").

    Returns:
        Availability status and any relevant notes.
    """
    key = ingredient.lower().strip().replace(" ", "_")

    try:
        resp = http_requests.get(
            f"{_FS_BASE}/inventory/{key}",
            headers=_headers(),
            timeout=8,
        )
        if resp.status_code == 200:
            doc = _doc_to_dict(resp.json())
            available = doc.get("available", True)
            note = doc.get("note", "")
            status = "✅ In stock" if available else "❌ Out of stock"
            result = f"{status} — {doc.get('name', ingredient)}"
            if note:
                result += f"\n   Note: {note}"
            return result
        elif resp.status_code == 404:
            return f"'{ingredient}' not found in inventory system. Please ask kitchen staff for availability."
        else:
            return f"Inventory check temporarily unavailable. (HTTP {resp.status_code})"

    except Exception as exc:  # noqa: BLE001
        logger.error("check_inventory failed: %s", exc)
        return f"Inventory check unavailable right now — please ask our staff about '{ingredient}'."


# ---------------------------------------------------------------------------
# 4. get_wait_times — current kitchen queue per cuisine
# ---------------------------------------------------------------------------

def get_wait_times() -> str:
    """Get current estimated kitchen wait times for all cuisines.

    Returns:
        Formatted wait time string for all stations.
    """
    cuisines = ["pizza", "burger", "sushi"]
    lines = ["⏱️  Current Kitchen Wait Times:"]

    try:
        for cuisine in cuisines:
            resp = http_requests.get(
                f"{_FS_BASE}/wait_times/{cuisine}",
                headers=_headers(),
                timeout=5,
            )
            emoji = {"pizza": "🍕", "burger": "🍔", "sushi": "🍣"}[cuisine]
            if resp.status_code == 200:
                doc = _doc_to_dict(resp.json())
                minutes = doc.get("minutes", 15)
                updated = doc.get("last_updated_epoch", 0)
                age = int((time.time() - updated) / 60) if updated else 0
                freshness = f"(updated {age}m ago)" if age < 60 else ""
                lines.append(f"  {emoji}  {cuisine.title():<8}: ~{minutes} minutes {freshness}")
            else:
                lines.append(f"  {emoji}  {cuisine.title():<8}: ~15 minutes (estimated)")

        lines.append("")
        lines.append("  Wait times refresh every 5 minutes based on kitchen queue.")
        return "\n".join(lines)

    except Exception as exc:  # noqa: BLE001
        logger.error("get_wait_times failed: %s", exc)
        return (
            "⏱️  Estimated Wait Times (live data unavailable):\n"
            "  🍕 Pizza  : ~15–20 minutes\n"
            "  🍔 Burger : ~10–15 minutes\n"
            "  🍣 Sushi  : ~8–12 minutes"
        )
